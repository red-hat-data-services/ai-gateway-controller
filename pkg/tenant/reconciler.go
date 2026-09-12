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
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
)

// notReadyRequeueInterval is used when an AITenant has opted into praxis
// but is not yet ready for it (see IsActive / GatewayRef). This is a "come
// back shortly" wait, distinct from ResyncInterval's steady-state resync.
const notReadyRequeueInterval = 10 * time.Second

// Reconciler watches AITenant CRs and, for every tenant whose
// AnnotationPayloadProcessingType annotation is "praxis", renders and
// SSA-applies a per-tenant copy of the vendored praxis-extproc manifests
// into that tenant's Gateway namespace (from status.gatewayRef). Tenants
// that don't opt into praxis (absent/empty/"ipp") are ignored:
// maas-controller's own TenantReconciler owns their IPP deployment.
//
// Reconciler does not write AITenant status. It does track, via
// PraxisCleanupFinalizer, whether it has (or may have) applied resources
// for a tenant, so it can delete them again when the tenant switches away
// from praxis or the AITenant is deleted — SSA only ever upserts the
// current render set, it never deletes what falls out of it.
type Reconciler struct {
	// Client applies the rendered resources and reads/updates AITenant.
	Client client.Client
	// ManifestPath is the kustomize entrypoint, e.g.
	// config/manifests/praxis-extproc/overlays/odh.
	ManifestPath string
	// Image replaces the vendored overlay's placeholder container image.
	Image string
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
	// down) would block AITenant deletion forever. Zero disables the
	// timeout and retries indefinitely.
	DeletionTimeout time.Duration
	// Log receives one entry per reconcile, plus any render/apply/cleanup
	// error.
	Log logr.Logger
}

// SetupWithManager registers the AITenant watch.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(NewAITenant()).
		Complete(r)
}

// Reconcile implements the logic documented on Reconciler.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("aitenant", req.NamespacedName)

	aitenant := NewAITenant()
	if err := r.Client.Get(ctx, req.NamespacedName, aitenant); err != nil {
		if apierrors.IsNotFound(err) {
			// Already fully gone: our finalizer (if we ever added one)
			// must have already been cleared, or we never added one.
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get AITenant %s: %w", req.NamespacedName, err)
	}

	tenantID := ID(req.Name)

	if !aitenant.GetDeletionTimestamp().IsZero() {
		return r.reconcileDelete(ctx, log, aitenant, tenantID)
	}

	if !UsesPraxis(aitenant) {
		return r.reconcileNotPraxis(ctx, log, aitenant, tenantID)
	}

	return r.reconcilePraxis(ctx, log, aitenant, tenantID)
}

// reconcilePraxis is the steady-state path for a tenant that currently
// opts into praxis: ensure the cleanup finalizer is present (before doing
// anything else, so even a partially-applied tenant is guaranteed a
// cleanup pass later), wait for readiness, then render/apply.
func (r *Reconciler) reconcilePraxis(ctx context.Context, log logr.Logger, aitenant *unstructured.Unstructured, tenantID string) (ctrl.Result, error) {
	if err := r.ensureFinalizer(ctx, aitenant); err != nil {
		return ctrl.Result{}, fmt.Errorf("ensure finalizer: %w", err)
	}

	if !IsActive(aitenant) {
		log.Info("AITenant opted into praxis but is not Active yet; will retry")
		return ctrl.Result{RequeueAfter: notReadyRequeueInterval}, nil
	}

	gatewayName, gatewayNamespace, ready := GatewayRef(aitenant)
	if !ready {
		log.Info("AITenant is Active but status.gatewayRef is not populated; will retry")
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
		// Not retryable until the AITenant's name (spec) changes: don't
		// requeue, or every resync would fail identically for the same
		// reason. A future spec update re-triggers reconciliation via the
		// watch.
		log.Error(err, "cannot render praxis-extproc resources for this tenant name; will not retry until the AITenant changes")
		return ctrl.Result{}, nil
	}

	if err := render.Apply(ctx, r.Client, resources); err != nil {
		log.Error(err, "praxis-extproc apply failed for tenant; will retry")
		return ctrl.Result{}, fmt.Errorf("apply: %w", err)
	}

	log.Info("praxis-extproc install applied",
		"tenantID", tenantID, "namespace", gatewayNamespace, "gatewayName", gatewayName)
	return ctrl.Result{RequeueAfter: r.ResyncInterval}, nil
}

// reconcileNotPraxis handles a tenant that currently does not opt into
// praxis. If our finalizer is present, this tenant previously opted in and
// has since switched away (or dropped the annotation): clean up whatever
// was applied before releasing the finalizer. Otherwise this tenant never
// used praxis and there is nothing to do.
func (r *Reconciler) reconcileNotPraxis(ctx context.Context, log logr.Logger, aitenant *unstructured.Unstructured, tenantID string) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(aitenant, PraxisCleanupFinalizer) {
		log.V(1).Info("AITenant does not use the praxis payload processing backend; nothing to do")
		return ctrl.Result{}, nil
	}

	if _, gatewayNamespace, ready := GatewayRef(aitenant); ready {
		if err := r.cleanup(ctx, tenantID, gatewayNamespace); err != nil {
			log.Error(err, "praxis-extproc cleanup failed after switching away from praxis; will retry", "namespace", gatewayNamespace)
			return ctrl.Result{}, fmt.Errorf("cleanup: %w", err)
		}
		log.Info("praxis-extproc resources cleaned up after switching away from praxis", "tenantID", tenantID, "namespace", gatewayNamespace)
	}

	if err := r.removeFinalizer(ctx, aitenant); err != nil {
		return ctrl.Result{}, fmt.Errorf("remove finalizer: %w", err)
	}
	return ctrl.Result{}, nil
}

// reconcileDelete handles a tenant whose AITenant is being deleted.
func (r *Reconciler) reconcileDelete(ctx context.Context, log logr.Logger, aitenant *unstructured.Unstructured, tenantID string) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(aitenant, PraxisCleanupFinalizer) {
		// We never opted this tenant in (or already finished cleanup):
		// nothing for us to do, and no finalizer of ours blocking deletion.
		return ctrl.Result{}, nil
	}

	if r.DeletionTimeout > 0 && time.Since(aitenant.GetDeletionTimestamp().Time) >= r.DeletionTimeout {
		log.Error(nil, "praxis-extproc cleanup exceeded deletion timeout; force-removing finalizer without confirming cleanup succeeded",
			"tenantID", tenantID, "timeout", r.DeletionTimeout)
		return ctrl.Result{}, r.removeFinalizer(ctx, aitenant)
	}

	_, gatewayNamespace, ready := GatewayRef(aitenant)
	if !ready {
		// Never got far enough to have a target namespace, so nothing was
		// ever applied for this tenant.
		log.Info("AITenant deleted before status.gatewayRef was ever populated; skipping cleanup")
		return ctrl.Result{}, r.removeFinalizer(ctx, aitenant)
	}

	if err := r.cleanup(ctx, tenantID, gatewayNamespace); err != nil {
		log.Error(err, "praxis-extproc cleanup failed for deleted tenant; will retry", "namespace", gatewayNamespace)
		return ctrl.Result{}, fmt.Errorf("cleanup: %w", err)
	}

	log.Info("praxis-extproc resources cleaned up for deleted tenant", "tenantID", tenantID, "namespace", gatewayNamespace)
	return ctrl.Result{}, r.removeFinalizer(ctx, aitenant)
}

// ensureFinalizer adds PraxisCleanupFinalizer if not already present.
func (r *Reconciler) ensureFinalizer(ctx context.Context, aitenant *unstructured.Unstructured) error {
	if controllerutil.ContainsFinalizer(aitenant, PraxisCleanupFinalizer) {
		return nil
	}
	base := aitenant.DeepCopy()
	controllerutil.AddFinalizer(aitenant, PraxisCleanupFinalizer)
	if err := r.Client.Patch(ctx, aitenant, client.MergeFrom(base)); err != nil {
		return err
	}
	return nil
}

// removeFinalizer removes PraxisCleanupFinalizer if present.
func (r *Reconciler) removeFinalizer(ctx context.Context, aitenant *unstructured.Unstructured) error {
	if !controllerutil.ContainsFinalizer(aitenant, PraxisCleanupFinalizer) {
		return nil
	}
	base := aitenant.DeepCopy()
	controllerutil.RemoveFinalizer(aitenant, PraxisCleanupFinalizer)
	if err := r.Client.Patch(ctx, aitenant, client.MergeFrom(base)); err != nil {
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
		obj := &unstructured.Unstructured{}
		obj.SetGroupVersionKind(t.gvk)
		obj.SetName(t.name)
		obj.SetNamespace(t.namespace)
		if err := client.IgnoreNotFound(r.Client.Delete(ctx, obj)); err != nil {
			return fmt.Errorf("delete %s %s/%s: %w", t.gvk.Kind, t.namespace, t.name, err)
		}
	}
	return nil
}
