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

// Package consumerportal reconciles the MaaS consumer portal OIDC auth proxy
// (kube-auth-proxy) described in ODH-ADR-MS-0008. The proxy runs as a
// standalone Deployment in the tenant's infrastructure namespace, independent
// of the RHOAI Platform GatewayConfig. For the MVP only the default AITenant
// serves the consumer portal.
package consumerportal

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/constants"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/tenant"
)

const (
	// AuthProxyName names every auth proxy resource. It differs from the
	// platform's openshift-ingress/kube-auth-proxy, which serves the RHOAI
	// dashboard gateway.
	AuthProxyName = "maas-consumer-portal-auth-proxy"
	// CredentialsSecretName holds OAUTH2_PROXY_CLIENT_ID,
	// OAUTH2_PROXY_CLIENT_SECRET, and OAUTH2_PROXY_COOKIE_SECRET in the
	// infrastructure namespace.
	CredentialsSecretName = AuthProxyName + "-creds"
	// CleanupFinalizer removes the auth proxy, which lives in another
	// namespace than the MaasTenantConfig and so cannot use owner references.
	CleanupFinalizer = "ai-gateway-controller.opendatahub.io/consumer-portal-cleanup"
	// DefaultAuthorinoNamespace is where Kuadrant runs Authorino.
	DefaultAuthorinoNamespace = "kuadrant-system"
)

var (
	gvkGateway       = schema.GroupVersionKind{Group: "gateway.networking.k8s.io", Version: "v1", Kind: "Gateway"}
	authProxyObjects = []schema.GroupVersionKind{
		{Group: "apps", Version: "v1", Kind: "Deployment"},
		{Version: "v1", Kind: "Service"},
		{Version: "v1", Kind: "ServiceAccount"},
		{Group: "networking.k8s.io", Version: "v1", Kind: "NetworkPolicy"},
	}
)

// Reconciler deploys the consumer portal auth proxy for the default AITenant.
type Reconciler struct {
	Client    client.Client
	APIReader client.Reader
	Log       logr.Logger
	// ManifestPath is the kustomize entrypoint for the auth proxy resources,
	// e.g. /config/manifests/consumer-portal/base.
	ManifestPath string
	// Image is the kube-auth-proxy container image.
	Image string
	// AuthorinoNamespace is allowed through the auth proxy NetworkPolicy.
	AuthorinoNamespace string
	// ResyncInterval is the RequeueAfter used once the proxy is applied.
	ResyncInterval time.Duration
}

// SetupWithManager watches MaasTenantConfig (primary) and the default
// AITenant, which carries the OIDC settings and the Gateway reference.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("consumer-portal").
		For(tenant.NewMaasTenantConfig()).
		Watches(tenant.NewAITenant(), handler.EnqueueRequestsFromMapFunc(r.maasTenantConfigForAITenant)).
		Complete(r)
}

func (r *Reconciler) maasTenantConfigForAITenant(_ context.Context, obj client.Object) []reconcile.Request {
	aitenant, ok := obj.(*unstructured.Unstructured)
	if !ok || aitenant.GetName() != tenant.DefaultAITenantName {
		return nil
	}
	namespace, ok := tenant.ConfigNamespace(aitenant)
	if !ok {
		return nil
	}
	return []reconcile.Request{{NamespacedName: types.NamespacedName{
		Namespace: namespace,
		Name:      tenant.MaasTenantConfigInstanceName,
	}}}
}

// Reconcile applies the auth proxy when the default AITenant is ready, has a
// Gateway, enables the consumer portal, and configures OIDC. Otherwise it
// removes any proxy it previously created.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("maastenantconfig", req.NamespacedName)

	mtc := tenant.NewMaasTenantConfig()
	if err := r.Client.Get(ctx, req.NamespacedName, mtc); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get MaasTenantConfig %s: %w", req.NamespacedName, err)
	}
	infraNamespace := InfraNamespace(mtc)

	if !mtc.GetDeletionTimestamp().IsZero() {
		return ctrl.Result{}, r.disable(ctx, mtc, infraNamespace)
	}
	if !IsDefaultTenant(mtc) {
		return ctrl.Result{}, r.disable(ctx, mtc, infraNamespace)
	}

	aitenant, err := r.resolveOwnedAITenant(ctx, mtc)
	if err != nil {
		return ctrl.Result{}, err
	}
	if aitenant == nil || !tenant.DeployReady(aitenant) {
		log.Info("default AITenant is not ready yet; will retry")
		return ctrl.Result{RequeueAfter: constants.NotReadyRequeueInterval}, nil
	}
	if !PortalEnabled(aitenant) {
		log.Info("consumer portal is disabled on the default AITenant; removing the auth proxy")
		return ctrl.Result{}, r.disable(ctx, mtc, infraNamespace)
	}
	issuerURL := OIDCIssuerURL(aitenant)
	if issuerURL == "" {
		// OpenShift OAuth mode is not implemented yet; only OIDC mode is.
		log.Info("default AITenant has no OIDC issuer; OpenShift OAuth mode is not supported yet, removing the auth proxy")
		return ctrl.Result{}, r.disable(ctx, mtc, infraNamespace)
	}
	if infraNamespace == "" {
		log.Info("MaasTenantConfig status.infraNamespace is not populated yet; will retry")
		return ctrl.Result{RequeueAfter: constants.NotReadyRequeueInterval}, nil
	}

	gatewayName, gatewayNamespace, ok := tenant.GatewayRef(aitenant)
	if !ok {
		log.Info("default AITenant status.gatewayRef is not populated yet; will retry")
		return ctrl.Result{RequeueAfter: constants.NotReadyRequeueInterval}, nil
	}
	hostname, err := r.gatewayHostname(ctx, gatewayNamespace, gatewayName)
	if err != nil {
		log.Info("cannot determine the Gateway hostname for the OIDC callback; will retry", "error", err)
		return ctrl.Result{RequeueAfter: constants.NotReadyRequeueInterval}, nil
	}

	// The proxy cannot start without its client and cookie secrets, so wait
	// for them instead of creating a pod that fails on a missing Secret.
	secret := &corev1.Secret{}
	if err := r.APIReader.Get(ctx, client.ObjectKey{Namespace: infraNamespace, Name: CredentialsSecretName}, secret); err != nil {
		if apierrors.IsNotFound(err) {
			log.Info("auth proxy credentials Secret does not exist yet; will retry",
				"namespace", infraNamespace, "secret", CredentialsSecretName)
			return ctrl.Result{RequeueAfter: constants.NotReadyRequeueInterval}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get Secret %s/%s: %w", infraNamespace, CredentialsSecretName, err)
	}

	caKeys, err := r.providerCAKeys(ctx, infraNamespace)
	if err != nil {
		return ctrl.Result{}, err
	}

	if err := r.ensureFinalizer(ctx, mtc); err != nil {
		return ctrl.Result{}, fmt.Errorf("ensure finalizer: %w", err)
	}

	rendered, err := render.Build(r.ManifestPath)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("render: %w", err)
	}
	resources := Render(rendered, Params{
		Namespace:          infraNamespace,
		Image:              r.Image,
		OIDCIssuerURL:      issuerURL,
		Hostname:           hostname,
		GatewayName:        gatewayName,
		GatewayNamespace:   gatewayNamespace,
		AuthorinoNamespace: r.authorinoNamespace(),
		ProviderCAKeys:     caKeys,
	})
	if err := render.Apply(ctx, r.Client, resources); err != nil {
		return ctrl.Result{}, fmt.Errorf("apply: %w", err)
	}

	log.Info("consumer portal auth proxy applied", "namespace", infraNamespace, "hostname", hostname)
	return ctrl.Result{RequeueAfter: r.ResyncInterval}, nil
}

// disable removes the auth proxy and releases the finalizer. It is a no-op
// when this reconciler never deployed the proxy for the MaasTenantConfig.
func (r *Reconciler) disable(ctx context.Context, mtc *unstructured.Unstructured, infraNamespace string) error {
	if !controllerutil.ContainsFinalizer(mtc, CleanupFinalizer) {
		return nil
	}
	if infraNamespace != "" {
		if err := r.cleanup(ctx, infraNamespace); err != nil {
			return err
		}
	}
	// The optimistic lock keeps this merge patch, which replaces the whole
	// finalizers array, from dropping another controller's finalizer.
	patch := client.MergeFromWithOptions(mtc.DeepCopy(), client.MergeFromWithOptimisticLock{})
	controllerutil.RemoveFinalizer(mtc, CleanupFinalizer)
	if err := r.Client.Patch(ctx, mtc, patch); err != nil {
		return fmt.Errorf("remove finalizer: %w", err)
	}
	return nil
}

// cleanup deletes the auth proxy resources this controller owns. Objects
// without the ai-gateway-controller managed-by label are left alone.
func (r *Reconciler) cleanup(ctx context.Context, namespace string) error {
	for _, gvk := range authProxyObjects {
		obj := &unstructured.Unstructured{}
		obj.SetGroupVersionKind(gvk)
		if err := r.APIReader.Get(ctx, client.ObjectKey{Namespace: namespace, Name: AuthProxyName}, obj); err != nil {
			if apierrors.IsNotFound(err) {
				continue
			}
			return fmt.Errorf("get %s %s/%s: %w", gvk.Kind, namespace, AuthProxyName, err)
		}
		if obj.GetLabels()[tenant.LabelManagedBy] != tenant.ManagedByAIGatewayController {
			continue
		}
		if err := r.Client.Delete(ctx, obj); err != nil && !apierrors.IsNotFound(err) {
			return fmt.Errorf("delete %s %s/%s: %w", gvk.Kind, namespace, AuthProxyName, err)
		}
	}
	return nil
}

func (r *Reconciler) ensureFinalizer(ctx context.Context, mtc *unstructured.Unstructured) error {
	if controllerutil.ContainsFinalizer(mtc, CleanupFinalizer) {
		return nil
	}
	// The optimistic lock keeps this merge patch, which replaces the whole
	// finalizers array, from dropping another controller's finalizer.
	patch := client.MergeFromWithOptions(mtc.DeepCopy(), client.MergeFromWithOptimisticLock{})
	controllerutil.AddFinalizer(mtc, CleanupFinalizer)
	return r.Client.Patch(ctx, mtc, patch)
}

// resolveOwnedAITenant returns the AITenant named by the MaasTenantConfig's
// owning-AITenant annotations, or nil when they are unset or the AITenant does
// not exist. Annotations are user-editable, so ownership is confirmed through
// the AITenant's status.tenantNamespace.
func (r *Reconciler) resolveOwnedAITenant(ctx context.Context, mtc *unstructured.Unstructured) (*unstructured.Unstructured, error) {
	name, namespace, ok := tenant.OwningAITenantRef(mtc)
	if !ok {
		return nil, nil
	}
	aitenant := tenant.NewAITenant()
	if err := r.Client.Get(ctx, client.ObjectKey{Name: name, Namespace: namespace}, aitenant); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("get owning AITenant %s/%s: %w", namespace, name, err)
	}
	if owned, ok := tenant.ConfigNamespace(aitenant); !ok || owned != mtc.GetNamespace() {
		return nil, fmt.Errorf("AITenant %s/%s status.tenantNamespace %q does not own MaasTenantConfig in %q",
			namespace, name, owned, mtc.GetNamespace())
	}
	return aitenant, nil
}

// gatewayHostname returns the hostname of the Gateway's first HTTPS listener
// with a concrete hostname. The OIDC callback is served on that hostname.
func (r *Reconciler) gatewayHostname(ctx context.Context, namespace, name string) (string, error) {
	gw := &unstructured.Unstructured{}
	gw.SetGroupVersionKind(gvkGateway)
	if err := r.APIReader.Get(ctx, client.ObjectKey{Namespace: namespace, Name: name}, gw); err != nil {
		return "", fmt.Errorf("get Gateway %s/%s: %w", namespace, name, err)
	}
	hostname := ListenerHostname(gw)
	if hostname == "" {
		return "", fmt.Errorf("gateway %s/%s has no HTTPS listener with a concrete hostname", namespace, name)
	}
	return hostname, nil
}

// providerCAKeys returns the odh-trusted-ca-bundle keys that contain
// certificates. The bundle is optional, and the platform leaves its custom CA
// key empty when no custom CA is configured.
func (r *Reconciler) providerCAKeys(ctx context.Context, namespace string) ([]string, error) {
	bundle := &corev1.ConfigMap{}
	if err := r.APIReader.Get(ctx, client.ObjectKey{Namespace: namespace, Name: TrustedCABundleConfigMap}, bundle); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("get ConfigMap %s/%s: %w", namespace, TrustedCABundleConfigMap, err)
	}
	var keys []string
	for _, key := range TrustedCABundleKeys {
		if strings.Contains(bundle.Data[key], "BEGIN CERTIFICATE") {
			keys = append(keys, key)
		}
	}
	return keys, nil
}

func (r *Reconciler) authorinoNamespace() string {
	if r.AuthorinoNamespace == "" {
		return DefaultAuthorinoNamespace
	}
	return r.AuthorinoNamespace
}
