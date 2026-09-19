/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package tenant

import (
	"context"
	"fmt"
	"time"

	"github.com/go-logr/logr"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
)

// notReadyRequeueInterval is used when a MaasTenantConfig has opted into
// praxis but is not yet ready for it (see IsActive / GatewayRef), or when a
// transition-in is blocked on the IPP migration marker. This is a "come
// back shortly" wait, distinct from ResyncInterval's steady-state resync.
const notReadyRequeueInterval = 10 * time.Second

// Reconciler primarily watches MaasTenantConfig CRs (owned by
// maas-controller) — mirroring maas-controller's own TenantReconciler — and,
// for every tenant whose AnnotationPayloadProcessingType annotation is
// "praxis", renders and SSA-applies a per-tenant copy of the vendored
// praxis-extproc manifests into that tenant's Gateway namespace. Tenants
// that don't opt into praxis (absent/empty/other) are ignored:
// maas-controller's own TenantReconciler owns their IPP deployment.
//
// Reconciler still Gets a tenant's owning AITenant (see
// OwningAITenantRef / GatewayRef / IsActive) — status.gatewayRef and
// status.phase live there, not on MaasTenantConfig — but no longer watches
// AITenant as its primary trigger; it only watches AITenant secondarily, to
// react to gatewayRef/phase changes that AnnotationPayloadProcessingType
// alone would miss.
//
// Reconciler does not write AITenant at all (status or otherwise). It does
// track, via PraxisCleanupFinalizer on MaasTenantConfig, whether it has (or
// may have) applied resources for a tenant, so it can delete them again
// when the tenant switches away from praxis or the MaasTenantConfig is
// deleted — SSA only ever upserts the current render set, it never deletes
// what falls out of it.
type Reconciler struct {
	// Client applies the rendered resources and reads/updates MaasTenantConfig
	// (and reads AITenant).
	Client client.Client
	// ManifestPath is the kustomize entrypoint, e.g.
	// config/manifests/praxis-extproc/overlays/odh.
	ManifestPath string
	// Image replaces the vendored overlay's placeholder container image.
	Image string
	// SkipNetworkPolicy omits the controller-managed payload-processing
	// NetworkPolicy when an installation supplies equivalent networking and the
	// target namespace disallows this controller from creating policies. It is
	// false by default and must be set explicitly by the installer.
	SkipNetworkPolicy bool
	// MaaSAPIRouteNameBase is the base name used to disable ext_proc on
	// maas-api's own HTTPRoute rules; suffixed per tenant like every other
	// resource this package renames.
	MaaSAPIRouteNameBase string
	// ResyncInterval is the RequeueAfter used once a tenant's resources have
	// been successfully applied, so drift gets corrected periodically even
	// without a new watch event (mirrors maas-controller's TenantReconciler
	// setFinalStatus, and this controller's own former --resync-interval
	// ticker). Must be positive.
	ResyncInterval time.Duration
	// DeletionTimeout bounds how long Reconcile keeps retrying cleanup
	// before force-removing PraxisCleanupFinalizer without confirming
	// cleanup succeeded (mirrors maas-controller's
	// AITenantReconciler.DeletionTimeout / forceRemoveAITenantFinalizer):
	// without this, a persistent cleanup failure (or this controller being
	// down) would block MaasTenantConfig (and therefore AITenant) deletion
	// forever. Zero disables the timeout and retries indefinitely.
	DeletionTimeout time.Duration
	// Log receives one entry per reconcile, plus any render/apply/cleanup
	// error.
	Log logr.Logger
}

// SetupWithManager registers the MaasTenantConfig watch (primary trigger)
// and a secondary AITenant watch mapped back to the owning MaasTenantConfig,
// mirroring maas-controller's own TenantReconciler.SetupWithManager shape.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(NewMaasTenantConfig()).
		Watches(
			NewAITenant(),
			handler.EnqueueRequestsFromMapFunc(r.enqueueMaasTenantConfigForAITenant),
		).
		Complete(r)
}

// enqueueMaasTenantConfigForAITenant maps an AITenant event to the
// MaasTenantConfig it owns, via status.tenantNamespace (see
// ConfigNamespace) — avoiding any need to duplicate maas-controller's
// TenantNamespaceForAITenant naming convention, which depends on a
// configurable default tenant namespace this controller does not know.
func (r *Reconciler) enqueueMaasTenantConfigForAITenant(_ context.Context, obj client.Object) []reconcile.Request {
	u, ok := obj.(*unstructured.Unstructured)
	if !ok {
		return nil
	}
	namespace, ok := ConfigNamespace(u)
	if !ok {
		return nil
	}
	return []reconcile.Request{{NamespacedName: types.NamespacedName{
		Namespace: namespace,
		Name:      MaasTenantConfigInstanceName,
	}}}
}

// Reconcile implements the logic documented on Reconciler.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("maastenantconfig", req.NamespacedName)

	mtc := NewMaasTenantConfig()
	if err := r.Client.Get(ctx, req.NamespacedName, mtc); err != nil {
		if apierrors.IsNotFound(err) {
			// Already fully gone: our finalizer (if we ever added one)
			// must have already been cleared, or we never added one.
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get MaasTenantConfig %s: %w", req.NamespacedName, err)
	}

	tenantID := IdentifierFor(mtc)

	if !mtc.GetDeletionTimestamp().IsZero() {
		return r.reconcileDelete(ctx, log, mtc, tenantID)
	}

	if !UsesPraxis(mtc) {
		return r.reconcileNotPraxis(ctx, log, mtc, tenantID)
	}

	return r.reconcilePraxis(ctx, log, mtc, tenantID)
}

// resolveOwnedAITenant Gets the AITenant named by OwningAITenantRef and
// verifies status.tenantNamespace owns mtc. It does not require phase Active:
// cleanup/delete must still use status.gatewayRef while the AITenant is
// Terminating (otherwise PraxisCleanupFinalizer blocks MTC deletion until
// DeletionTimeout). A nil aitenant with a nil error means annotations aren't
// populated yet or the AITenant is gone — a normal transient state.
func (r *Reconciler) resolveOwnedAITenant(ctx context.Context, mtc *unstructured.Unstructured) (aitenant *unstructured.Unstructured, err error) {
	name, namespace, ok := OwningAITenantRef(mtc)
	if !ok {
		return nil, nil
	}
	aitenant = NewAITenant()
	if err := r.Client.Get(ctx, client.ObjectKey{Name: name, Namespace: namespace}, aitenant); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("get owning AITenant %s/%s: %w", namespace, name, err)
	}
	ownedNS, ownedOK := ConfigNamespace(aitenant)
	if !ownedOK || ownedNS != mtc.GetNamespace() {
		return nil, fmt.Errorf(
			"AITenant %s/%s status.tenantNamespace %q does not own MaasTenantConfig in %q; refusing spoofed owning-AITenant annotations",
			namespace, name, ownedNS, mtc.GetNamespace())
	}
	return aitenant, nil
}

// resolveOwningAITenant is resolveOwnedAITenant plus the Active readiness
// gate used by the praxis apply path.
func (r *Reconciler) resolveOwningAITenant(ctx context.Context, mtc *unstructured.Unstructured) (aitenant *unstructured.Unstructured, ready bool, err error) {
	aitenant, err = r.resolveOwnedAITenant(ctx, mtc)
	if err != nil || aitenant == nil {
		return aitenant, false, err
	}
	if !IsActive(aitenant) {
		return aitenant, false, nil
	}
	return aitenant, true, nil
}

// reconcilePraxis is the steady-state path for a tenant that currently
// opts into praxis: ensure the cleanup finalizer is present (before doing
// anything else, so even a partially-applied tenant is guaranteed a
// cleanup pass later), wait for readiness, then render/apply.
func (r *Reconciler) reconcilePraxis(ctx context.Context, log logr.Logger, mtc *unstructured.Unstructured, tenantID string) (ctrl.Result, error) {
	if err := r.ensureFinalizer(ctx, mtc); err != nil {
		return ctrl.Result{}, fmt.Errorf("ensure finalizer: %w", err)
	}

	aitenant, ready, err := r.resolveOwningAITenant(ctx, mtc)
	if err != nil {
		return ctrl.Result{}, err
	}
	if !ready {
		log.Info("MaasTenantConfig opted into praxis but owning AITenant is not Active yet; will retry")
		return ctrl.Result{RequeueAfter: notReadyRequeueInterval}, nil
	}

	gatewayName, gatewayNamespace, gwReady := GatewayRef(aitenant)
	if !gwReady {
		log.Info("owning AITenant is Active but status.gatewayRef is not populated; will retry")
		return ctrl.Result{RequeueAfter: notReadyRequeueInterval}, nil
	}

	// Handshake: claim cleanup-complete → steady. Absent means wait (existing
	// tenants are assumed to still run legacy IPP until they signal
	// cleanup-complete). Status itself is the durable claim — no bundleExists gate.
	ready, err = EnsurePraxisMayDeploy(ctx, r.Client, mtc)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("ensure praxis may deploy: %w", err)
	}
	if !ready {
		log.Info("waiting for the legacy IPP cleanup to finish before applying praxis-extproc")
		return ctrl.Result{RequeueAfter: notReadyRequeueInterval}, nil
	}

	rendered, err := render.Build(r.ManifestPath)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("render: %w", err)
	}

	resources := render.PostRender(rendered, render.Params{
		Namespace:        gatewayNamespace,
		GatewayName:      gatewayName,
		Image:            r.Image,
		MaaSAPIRouteName: ResourceName(r.MaaSAPIRouteNameBase, tenantID),
	})

	resources, err = Rename(resources, tenantID, gatewayNamespace)
	if err != nil {
		// Not retryable until the tenant's name changes: don't requeue, or
		// every resync would fail identically for the same reason. A future
		// change re-triggers reconciliation via the watch.
		log.Error(err, "cannot render praxis-extproc resources for this tenant name; will not retry until the tenant changes")
		return ctrl.Result{}, nil
	}
	if r.SkipNetworkPolicy {
		filtered := make([]unstructured.Unstructured, 0, len(resources))
		for _, resource := range resources {
			if resource.GetKind() != "NetworkPolicy" {
				filtered = append(filtered, resource)
			}
		}
		resources = filtered
		log.Info("omitting controller-managed NetworkPolicy by explicit configuration", "namespace", gatewayNamespace)
	}

	if err := render.Apply(ctx, r.Client, resources); err != nil {
		log.Error(err, "praxis-extproc apply failed for tenant; will retry")
		return ctrl.Result{}, fmt.Errorf("apply: %w", err)
	}

	// Drop any leftover tenant-scoped standalone Praxis hop from earlier
	// releases. ExtProc is the dataplane; ExternalModel routes backend to
	// provider ExternalName Services directly.
	if tenantNamespace, ok := ConfigNamespace(aitenant); ok {
		if err := r.deleteStandalonePraxis(ctx, tenantID, tenantNamespace); err != nil {
			return ctrl.Result{}, err
		}
	}

	log.Info("praxis-extproc install applied",
		"tenantID", tenantID, "namespace", gatewayNamespace, "gatewayName", gatewayName)
	return ctrl.Result{RequeueAfter: r.ResyncInterval}, nil
}

// deleteStandalonePraxis removes controller-owned standalone Praxis resources
// left from releases that deployed a tenant-scoped praxis-ai hop.
func (r *Reconciler) deleteStandalonePraxis(ctx context.Context, tenantID, tenantNamespace string) error {
	for _, t := range []struct {
		gvk  schema.GroupVersionKind
		name string
	}{
		{gvkServiceAccount, ResourceName(praxisServiceAccount, tenantID)},
		{gvkConfigMap, ResourceName(praxisConfigMapName, tenantID)},
		{gvkService, ResourceName(praxisServiceName, tenantID)},
		{gvkDeployment, ResourceName(praxisDeploymentName, tenantID)},
	} {
		if err := r.deleteResourceIfOwned(ctx, t.gvk, t.name, tenantNamespace); err != nil {
			return err
		}
	}
	return nil
}

// reconcileNotPraxis handles a tenant that currently does not opt into
// praxis. If our finalizer is present, this tenant previously opted in and
// has since switched away (or dropped the annotation): clean up whatever
// was applied, signal maas-controller that it may now (re)deploy legacy IPP
// (see MarkPayloadProcessingCleanupComplete), then release the finalizer.
// Otherwise this tenant never used praxis and there is nothing to do.
func (r *Reconciler) reconcileNotPraxis(ctx context.Context, log logr.Logger, mtc *unstructured.Unstructured, tenantID string) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(mtc, PraxisCleanupFinalizer) {
		log.V(1).Info("MaasTenantConfig does not use the praxis payload processing backend; nothing to do")
		return ctrl.Result{}, nil
	}

	aitenant, err := r.resolveOwnedAITenant(ctx, mtc)
	if err != nil {
		return ctrl.Result{}, err
	}
	if aitenant == nil {
		log.Info("waiting for owning AITenant before praxis-extproc cleanup after switch-away")
		return ctrl.Result{RequeueAfter: notReadyRequeueInterval}, nil
	}
	_, gatewayNamespace, gwReady := GatewayRef(aitenant)
	if !gwReady {
		log.Info("waiting for status.gatewayRef before praxis-extproc cleanup after switch-away")
		return ctrl.Result{RequeueAfter: notReadyRequeueInterval}, nil
	}

	if err := r.cleanup(ctx, tenantID, gatewayNamespace); err != nil {
		log.Error(err, "praxis-extproc cleanup failed after switching away from praxis; will retry", "namespace", gatewayNamespace)
		return ctrl.Result{}, fmt.Errorf("cleanup: %w", err)
	}
	if tenantNamespace, ok := ConfigNamespace(aitenant); ok {
		if err := r.deleteStandalonePraxis(ctx, tenantID, tenantNamespace); err != nil {
			return ctrl.Result{}, fmt.Errorf("cleanup standalone praxis: %w", err)
		}
	}
	if err := MarkPayloadProcessingCleanupComplete(ctx, r.Client, mtc); err != nil {
		return ctrl.Result{}, fmt.Errorf("mark payload-processing cleanup complete: %w", err)
	}
	log.Info("praxis-extproc resources cleaned up after switching away from praxis", "tenantID", tenantID, "namespace", gatewayNamespace)

	if err := r.removeFinalizer(ctx, mtc); err != nil {
		return ctrl.Result{}, fmt.Errorf("remove finalizer: %w", err)
	}
	return ctrl.Result{}, nil
}

// reconcileDelete handles a tenant whose MaasTenantConfig is being deleted.
func (r *Reconciler) reconcileDelete(ctx context.Context, log logr.Logger, mtc *unstructured.Unstructured, tenantID string) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(mtc, PraxisCleanupFinalizer) {
		// We never opted this tenant in (or already finished cleanup):
		// nothing for us to do, and no finalizer of ours blocking deletion.
		return ctrl.Result{}, nil
	}

	if r.DeletionTimeout > 0 && time.Since(mtc.GetDeletionTimestamp().Time) >= r.DeletionTimeout {
		log.Error(nil, "praxis-extproc cleanup exceeded deletion timeout; force-removing finalizer without confirming cleanup succeeded",
			"tenantID", tenantID, "timeout", r.DeletionTimeout)
		return ctrl.Result{}, r.removeFinalizer(ctx, mtc)
	}

	aitenant, err := r.resolveOwnedAITenant(ctx, mtc)
	if err != nil {
		return ctrl.Result{}, err
	}
	if aitenant == nil {
		log.Info("MaasTenantConfig deleting but owning AITenant is not resolvable yet; will retry cleanup")
		return ctrl.Result{RequeueAfter: notReadyRequeueInterval}, nil
	}

	_, gatewayNamespace, gwReady := GatewayRef(aitenant)
	if !gwReady {
		log.Info("MaasTenantConfig deleting but status.gatewayRef is not populated; will retry cleanup")
		return ctrl.Result{RequeueAfter: notReadyRequeueInterval}, nil
	}

	if err := r.cleanup(ctx, tenantID, gatewayNamespace); err != nil {
		log.Error(err, "praxis-extproc cleanup failed for deleted tenant; will retry", "namespace", gatewayNamespace)
		return ctrl.Result{}, fmt.Errorf("cleanup: %w", err)
	}
	if tenantNamespace, ok := ConfigNamespace(aitenant); ok {
		if err := r.deleteStandalonePraxis(ctx, tenantID, tenantNamespace); err != nil {
			return ctrl.Result{}, fmt.Errorf("cleanup standalone praxis: %w", err)
		}
	}

	log.Info("praxis-extproc resources cleaned up for deleted tenant", "tenantID", tenantID, "namespace", gatewayNamespace)
	return ctrl.Result{}, r.removeFinalizer(ctx, mtc)
}

// ensureFinalizer adds PraxisCleanupFinalizer if not already present.
func (r *Reconciler) ensureFinalizer(ctx context.Context, mtc *unstructured.Unstructured) error {
	if controllerutil.ContainsFinalizer(mtc, PraxisCleanupFinalizer) {
		return nil
	}
	base := mtc.DeepCopy()
	controllerutil.AddFinalizer(mtc, PraxisCleanupFinalizer)
	if err := r.Client.Patch(ctx, mtc, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{})); err != nil {
		return err
	}
	return nil
}

// removeFinalizer removes PraxisCleanupFinalizer if present.
func (r *Reconciler) removeFinalizer(ctx context.Context, mtc *unstructured.Unstructured) error {
	if !controllerutil.ContainsFinalizer(mtc, PraxisCleanupFinalizer) {
		return nil
	}
	base := mtc.DeepCopy()
	controllerutil.RemoveFinalizer(mtc, PraxisCleanupFinalizer)
	if err := r.Client.Patch(ctx, mtc, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{})); err != nil {
		return err
	}
	return nil
}

// cleanup deletes (ignoring not-found) every resource this controller
// would have applied for tenantID in namespace, mirroring
// tenantreconcile.cleanupTenantResources / cleanupPayloadProcessingHPA in
// maas-controller: SSA only ever upserts the current render set, it never
// deletes what falls out of it. The shared payload-processing-reader
// ClusterRole is never deleted here: every tenant's ClusterRoleBinding
// references that one role, so deleting it would break every other
// praxis tenant sharing the cluster.
func (r *Reconciler) cleanup(ctx context.Context, tenantID, namespace string) error {
	type target struct {
		gvk       schema.GroupVersionKind
		name      string
		namespace string
	}

	targets := []target{
		{gvkDeployment, PayloadProcessingDeploymentName(tenantID), namespace},
		{gvkDeployment, PayloadPreProcessingDeploymentName(tenantID), namespace},
		{gvkService, PayloadProcessingServiceName(tenantID), namespace},
		{gvkService, PayloadPreProcessingServiceName(tenantID), namespace},
		{gvkConfigMap, PayloadProcessingPluginsConfigMapForTenant(tenantID), namespace},
		{gvkServiceAccount, PayloadProcessingServiceAccountName(tenantID), namespace},
		{gvkNetworkPolicy, PayloadProcessingNetworkPolicyName(tenantID), namespace},
		{gvkEnvoyFilter, PayloadProcessingEnvoyFilterName(tenantID), namespace},
		{gvkDestinationRule, PayloadProcessingServiceName(tenantID), namespace},
		{gvkDestinationRule, PayloadPreProcessingServiceName(tenantID), namespace},
		{gvkClusterRoleBinding, PayloadProcessingReaderClusterRoleBindingNameForTenant(tenantID), ""},
	}

	for _, t := range targets {
		if err := r.deleteResourceIfOwned(ctx, t.gvk, t.name, t.namespace); err != nil {
			return err
		}
	}
	return nil
}

func (r *Reconciler) deleteResourceIfOwned(ctx context.Context, gvk schema.GroupVersionKind, name, namespace string) error {
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(gvk)
	obj.SetName(name)
	obj.SetNamespace(namespace)
	if err := r.Client.Get(ctx, client.ObjectKeyFromObject(obj), obj); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return fmt.Errorf("get %s %s/%s: %w", gvk.Kind, namespace, name, err)
	}
	if !shouldDeletePraxisResource(obj) {
		return nil
	}
	if err := client.IgnoreNotFound(r.Client.Delete(ctx, obj)); err != nil {
		return fmt.Errorf("delete %s %s/%s: %w", gvk.Kind, namespace, name, err)
	}
	return nil
}
