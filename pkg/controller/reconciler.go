// Package controller contains the ExternalModel and ExternalProvider control loop.
package controller

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	apiMeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	"sigs.k8s.io/controller-runtime/pkg/source"

	v1alpha1 "github.com/opendatahub-io/ai-gateway-controller/api/inference/v1alpha1"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/envelope"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/publisher"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/resolver"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/tenant"
)

const (
	conditionReady              = "Ready"
	conditionOverlayDistributed = "OverlayDistributed"
	reasonReconciled            = "Reconciled"
	reasonReconcileFailed       = "ReconcileFailed"
	reasonNotPraxis             = "NotPraxisTenant"
	reasonTenantNotReady        = "TenantNotReady"
	reasonNoRoutes              = "NoRoutes"
	reasonProviderNotReady      = "ProviderNotReady"
	reasonClusterAllowlist      = "ClusterAllowlistMissing"
	providerServicePrefix       = "provider-"
	modelRoutePrefix            = "external-model-"
	externalModelFinalizer      = "inference.opendatahub.io/external-model-cleanup"
)

// Reconciler is the sole writer for the ExternalModel transport plane and the
// routing overlay. It resolves one namespace-scoped route set and renders both
// planes from that same result.
type Reconciler struct {
	client.Client
	// APIReader reads referenced Secret data directly from the API server. The
	// manager cache only watches Secret metadata to avoid caching credentials.
	APIReader        client.Reader
	Scheme           *runtime.Scheme
	Namespace        string
	GatewayName      string
	GatewayNamespace string
	Network          string
	LocalSite        string
	ConfigMap        string
	KnownClusters    []string
	Log              logr.Logger
	// ApplyResource and PublishOverlay are test seams. Production leaves them
	// nil, selecting the real SSA renderer and publisher below. Applying one
	// object at a time preserves the production order and lets tests inject a
	// failure at each SSA boundary without production-only flags.
	ApplyResource  func(context.Context, client.Client, unstructured.Unstructured) error
	PublishOverlay func(context.Context, *resolver.ResolvedRouteSet, envelope.Scope, envelope.Options) (publisher.Result, error)
}

// SetupWithManager registers model, provider, Secret, and AITenant watches.
// Provider and Secret changes fan out to every affected model in the same
// namespace; AITenant changes fan out to models in the tenant namespace.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	inScope := predicate.NewPredicateFuncs(func(obj client.Object) bool { return r.namespaceAllowed(obj.GetNamespace()) })
	return builder.ControllerManagedBy(mgr).
		For(&v1alpha1.ExternalModel{}, builder.WithPredicates(inScope)).
		Watches(&v1alpha1.ExternalProvider{}, handler.EnqueueRequestsFromMapFunc(r.providerModels), builder.WithPredicates(inScope)).
		WatchesMetadata(&corev1.Secret{}, handler.EnqueueRequestsFromMapFunc(r.secretModels), builder.WithPredicates(inScope)).
		// The tenant reconciler creates the tenant-local Praxis Service. A
		// model may otherwise publish an HTTPRoute before that Service exists;
		// Istio can retain ResolvedRefs=False until the route is reconciled
		// again. Service events are namespace-scoped and therefore only fan out
		// to models in the affected tenant.
		Watches(&corev1.Service{}, handler.EnqueueRequestsFromMapFunc(r.serviceModels), builder.WithPredicates(inScope)).
		WatchesRawSource(source.Kind(mgr.GetCache(), tenant.NewAITenant(), handler.TypedEnqueueRequestsFromMapFunc[*unstructured.Unstructured, reconcile.Request](r.tenantModels))).
		Complete(r)
}

func (r *Reconciler) providerModels(ctx context.Context, obj client.Object) []reconcile.Request {
	if !r.namespaceAllowed(obj.GetNamespace()) {
		return nil
	}
	return r.modelsReferencingProviders(ctx, obj.GetNamespace(), map[string]bool{obj.GetName(): true})
}

func (r *Reconciler) secretModels(ctx context.Context, obj client.Object) []reconcile.Request {
	if !r.namespaceAllowed(obj.GetNamespace()) {
		return nil
	}
	var providers v1alpha1.ExternalProviderList
	if err := r.List(ctx, &providers, client.InNamespace(obj.GetNamespace())); err != nil {
		r.Log.Error(err, "list providers for Secret event", "secret", obj.GetName())
		return nil
	}
	providerNames := map[string]bool{}
	for _, p := range providers.Items {
		if p.Spec.Auth.SecretRef.Name == obj.GetName() {
			providerNames[p.Name] = true
		}
	}
	return r.modelsReferencingProviders(ctx, obj.GetNamespace(), providerNames)
}

func (r *Reconciler) serviceModels(ctx context.Context, obj client.Object) []reconcile.Request {
	if !r.namespaceAllowed(obj.GetNamespace()) {
		return nil
	}
	return r.modelsInNamespace(ctx, obj.GetNamespace())
}

func (r *Reconciler) tenantModels(ctx context.Context, ait *unstructured.Unstructured) []reconcile.Request {
	ns, _, _ := unstructured.NestedString(ait.Object, "status", "tenantNamespace")
	if ns == "" {
		ns = ait.GetNamespace()
	}
	if !r.namespaceAllowed(ns) {
		return nil
	}
	return r.modelsInNamespace(ctx, ns)
}

func (r *Reconciler) modelsInNamespace(ctx context.Context, namespace string) []reconcile.Request {
	if !r.namespaceAllowed(namespace) {
		return nil
	}
	var models v1alpha1.ExternalModelList
	if err := r.List(ctx, &models, client.InNamespace(namespace)); err != nil {
		r.Log.Error(err, "list models for dependent event", "namespace", namespace)
		return nil
	}
	requests := make([]reconcile.Request, 0, len(models.Items))
	for i := range models.Items {
		requests = append(requests, reconcile.Request{NamespacedName: client.ObjectKeyFromObject(&models.Items[i])})
	}
	return requests
}

func (r *Reconciler) modelsReferencingProviders(ctx context.Context, namespace string, providers map[string]bool) []reconcile.Request {
	if len(providers) == 0 || !r.namespaceAllowed(namespace) {
		return nil
	}
	var models v1alpha1.ExternalModelList
	if err := r.List(ctx, &models, client.InNamespace(namespace)); err != nil {
		r.Log.Error(err, "list models for provider event", "namespace", namespace)
		return nil
	}
	requests := make([]reconcile.Request, 0, len(models.Items))
	for i := range models.Items {
		referencesProvider := false
		for _, ref := range models.Items[i].Spec.ExternalProviderRefs {
			if providers[ref.Ref.Name] {
				referencesProvider = true
				break
			}
		}
		if referencesProvider {
			requests = append(requests, reconcile.Request{NamespacedName: client.ObjectKeyFromObject(&models.Items[i])})
		}
	}
	return requests
}

// providerInputs validates providers before building the route set. The
// persisted phase is informational and may have been written by the
// handoff-side IPP controller; the Secret and transport reconciliation below
// are the authoritative gates for Praxis. Invalid providers remain excluded
// and fail closed.
func (r *Reconciler) providerInputs(ctx context.Context, namespace string) (
	v1alpha1.ExternalProviderList, []*v1alpha1.ExternalProvider,
	[]*v1alpha1.ExternalProvider, error,
) {
	var providers v1alpha1.ExternalProviderList
	if err := r.List(ctx, &providers, client.InNamespace(namespace)); err != nil {
		return providers, nil, nil, err
	}
	providerPtrs := make([]*v1alpha1.ExternalProvider, 0, len(providers.Items))
	validProviders := make([]*v1alpha1.ExternalProvider, 0, len(providers.Items))
	for i := range providers.Items {
		p := &providers.Items[i]
		if err := r.validateProvider(ctx, p); err != nil {
			if statusErr := r.updateProviderStatus(ctx, p, false, reasonReconcileFailed, err.Error()); statusErr != nil {
				return providers, nil, nil, statusErr
			}
			continue
		}
		ready := p.DeepCopy()
		if ready.Status.Phase != resolver.PhaseReady {
			ready.Status.Phase = resolver.PhaseReady
		}
		providerPtrs = append(providerPtrs, ready)
		validProviders = append(validProviders, p)
	}
	return providers, providerPtrs, validProviders, nil
}

// Reconcile applies provider resources, then model routes, then the overlay.
// The overlay is never published when an earlier stage fails.
func (r *Reconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	if !r.namespaceAllowed(req.Namespace) {
		return reconcile.Result{}, nil
	}
	var model v1alpha1.ExternalModel
	if err := r.Get(ctx, req.NamespacedName, &model); err != nil {
		if apierrors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}
	ait, found, err := r.praxisTenantForNamespace(ctx, req.Namespace)
	if err != nil {
		return reconcile.Result{}, err
	}
	if !found {
		if err := r.cleanupUnselectedModel(ctx, &model); err != nil {
			return reconcile.Result{}, err
		}
		return reconcile.Result{}, nil
	}
	if handled, err := r.handleModelLifecycle(ctx, &model, ait); handled {
		return reconcile.Result{}, err
	} else if err != nil {
		return reconcile.Result{}, err
	}
	if !tenant.IsActive(ait) {
		if err := r.updateModelStatus(ctx, &model, false, reasonTenantNotReady, "AITenant is selected for Praxis but is not Active", nil); err != nil {
			return reconcile.Result{}, err
		}
		return reconcile.Result{}, nil
	}
	gatewayName, gatewayNamespace := r.gatewayName(), r.gatewayNamespace()
	if selectedGateway, selectedNamespace, ok := tenant.GatewayRef(ait); ok {
		gatewayName, gatewayNamespace = selectedGateway, selectedNamespace
	}

	var models v1alpha1.ExternalModelList
	if err := r.List(ctx, &models, client.InNamespace(req.Namespace)); err != nil {
		return reconcile.Result{}, err
	}
	providers, providerPtrs, validProviders, err := r.providerInputs(ctx, req.Namespace)
	if err != nil {
		return reconcile.Result{}, err
	}

	modelPtrs := make([]*v1alpha1.ExternalModel, 0, len(models.Items))
	modelOwners := make(map[string]*v1alpha1.ExternalModel, len(models.Items))
	for i := range models.Items {
		modelPtrs = append(modelPtrs, &models.Items[i])
		modelOwners[models.Items[i].Name] = &models.Items[i]
	}
	providerOwners := make(map[string]*v1alpha1.ExternalProvider, len(providers.Items))
	for i := range providers.Items {
		providerOwners[providers.Items[i].Name] = &providers.Items[i]
	}
	set, err := resolver.Resolve(modelPtrs, providerPtrs)
	if err != nil {
		reason := reasonReconcileFailed
		if errors.Is(err, resolver.ErrNoRoutes) {
			reason = reasonProviderNotReady
		}
		if statusErr := r.updateModelStatus(ctx, &model, false, reason, err.Error(), nil); statusErr != nil {
			return reconcile.Result{}, statusErr
		}
		return reconcile.Result{}, err
	}
	if len(set.Routes()) == 0 {
		if cleanupErr := r.cleanupTransport(ctx, req.Namespace, nil); cleanupErr != nil {
			return reconcile.Result{}, cleanupErr
		}
		if cleanupErr := r.cleanupOverlay(ctx, req.Namespace); cleanupErr != nil {
			return reconcile.Result{}, cleanupErr
		}
		message := "no ExternalModel provider references resolved to a Ready provider"
		if statusErr := r.updateModelStatus(ctx, &model, false, reasonNoRoutes, message, nil); statusErr != nil {
			return reconcile.Result{}, statusErr
		}
		return reconcile.Result{}, resolver.ErrNoRoutes
	}
	if len(r.KnownClusters) == 0 {
		message := "no Praxis load_balancer clusters are configured; set at least one --known-cluster"
		if statusErr := r.updateModelStatus(ctx, &model, false, reasonClusterAllowlist, message, nil); statusErr != nil {
			return reconcile.Result{}, statusErr
		}
		return reconcile.Result{}, errors.New(message)
	}

	if err := r.applyTransport(ctx, set.Routes(), req.Namespace, gatewayName, gatewayNamespace, modelOwners, providerOwners); err != nil {
		for _, p := range validProviders {
			if statusErr := r.updateProviderStatus(ctx, p, false, reasonReconcileFailed, err.Error()); statusErr != nil {
				return reconcile.Result{}, statusErr
			}
		}
		if statusErr := r.updateModelStatus(ctx, &model, false, reasonReconcileFailed, err.Error(), nil); statusErr != nil {
			return reconcile.Result{}, statusErr
		}
		return reconcile.Result{}, err
	}
	if err := r.cleanupTransport(ctx, req.Namespace, set.Routes()); err != nil {
		if statusErr := r.updateModelStatus(ctx, &model, false, reasonReconcileFailed, err.Error(), nil); statusErr != nil {
			return reconcile.Result{}, statusErr
		}
		return reconcile.Result{}, err
	}
	for _, p := range validProviders {
		if statusErr := r.updateProviderStatus(ctx, p, true, reasonReconciled, "provider Secret reference and transport resources are ready"); statusErr != nil {
			return reconcile.Result{}, statusErr
		}
	}

	pub, err := publisher.New(r.Client, publisher.Config{Namespace: req.Namespace, Name: r.ConfigMap})
	if err != nil {
		return reconcile.Result{}, err
	}
	publish := r.PublishOverlay
	if publish == nil {
		publish = pub.Publish
	}
	result, err := publish(ctx, set, envelope.Scope{
		Network: r.Network, Gateway: gatewayName, Namespace: req.Namespace, LocalSite: r.localSite(),
	}, envelope.Options{
		KnownClusters: r.KnownClusters, SourceUID: string(model.UID), ProducerVersion: "dev",
	})
	if err != nil {
		if statusErr := r.updateModelStatus(ctx, &model, false, reasonReconcileFailed, err.Error(), nil); statusErr != nil {
			return reconcile.Result{}, statusErr
		}
		return reconcile.Result{}, err
	}

	message := fmt.Sprintf("distributed routing overlay digest %s generation %d", result.Envelope.Revision.Value, result.Envelope.Provenance.SourceGeneration)
	if err := r.updateModelStatus(ctx, &model, true, reasonReconciled, message, &result.Envelope); err != nil {
		return reconcile.Result{}, err
	}
	return reconcile.Result{}, nil
}

// cleanupUnselectedModel releases only resources owned by this controller when
// the tenant no longer selects Praxis. The default IPP path is not targeted.
func (r *Reconciler) cleanupUnselectedModel(ctx context.Context, model *v1alpha1.ExternalModel) error {
	if err := r.cleanupTransport(ctx, model.Namespace, nil); err != nil {
		return err
	}
	if err := r.cleanupOverlay(ctx, model.Namespace); err != nil {
		return err
	}
	if controllerutil.ContainsFinalizer(model, externalModelFinalizer) {
		return r.removeExternalModelFinalizer(ctx, model)
	}
	return nil
}

func (r *Reconciler) handleModelLifecycle(ctx context.Context, model *v1alpha1.ExternalModel, ait *unstructured.Unstructured) (bool, error) {
	if !controllerutil.ContainsFinalizer(model, externalModelFinalizer) {
		if !model.DeletionTimestamp.IsZero() {
			return true, nil
		}
		controllerutil.AddFinalizer(model, externalModelFinalizer)
		if err := r.Update(ctx, model); err != nil {
			return true, fmt.Errorf("add ExternalModel cleanup finalizer: %w", err)
		}
	}
	if model.DeletionTimestamp.IsZero() {
		return false, nil
	}
	return true, r.reconcileDeletedModel(ctx, model, ait)
}

// reconcileDeletedModel republishes the namespace's remaining route set before
// releasing the ExternalModel finalizer. Deletion therefore does not depend on
// an unrelated sibling watch to remove stale transport or overlay state.
func (r *Reconciler) reconcileDeletedModel(ctx context.Context, deleted *v1alpha1.ExternalModel, ait *unstructured.Unstructured) error {
	var models v1alpha1.ExternalModelList
	if err := r.List(ctx, &models, client.InNamespace(deleted.Namespace)); err != nil {
		return fmt.Errorf("list remaining ExternalModels for deletion: %w", err)
	}
	modelPtrs := make([]*v1alpha1.ExternalModel, 0, len(models.Items))
	modelOwners := make(map[string]*v1alpha1.ExternalModel, len(models.Items))
	for i := range models.Items {
		m := &models.Items[i]
		if m.Name == deleted.Name || !m.DeletionTimestamp.IsZero() {
			continue
		}
		modelPtrs = append(modelPtrs, m)
		modelOwners[m.Name] = m
	}
	providers, providerPtrs, _, err := r.providerInputs(ctx, deleted.Namespace)
	if err != nil {
		return err
	}
	providerOwners := make(map[string]*v1alpha1.ExternalProvider, len(providers.Items))
	for i := range providers.Items {
		providerOwners[providers.Items[i].Name] = &providers.Items[i]
	}
	set, err := resolver.Resolve(modelPtrs, providerPtrs)
	if errors.Is(err, resolver.ErrNoRoutes) {
		// A sibling still exists but is temporarily unroutable: retain the
		// last-known-good transport and overlay and retry. Only final-model
		// deletion is allowed to remove the shared serving state.
		if len(modelPtrs) > 0 {
			return err
		}
		if err := r.cleanupTransport(ctx, deleted.Namespace, nil); err != nil {
			return err
		}
		if err := r.cleanupOverlay(ctx, deleted.Namespace); err != nil {
			return err
		}
		return r.removeExternalModelFinalizer(ctx, deleted)
	}
	if err != nil {
		return fmt.Errorf("resolve remaining ExternalModels after deletion: %w", err)
	}
	if len(r.KnownClusters) == 0 {
		return errors.New("no Praxis load_balancer clusters are configured while deleting ExternalModel")
	}
	gatewayName, gatewayNamespace := r.gatewayName(), r.gatewayNamespace()
	if selectedGateway, selectedNamespace, ok := tenant.GatewayRef(ait); ok {
		gatewayName, gatewayNamespace = selectedGateway, selectedNamespace
	}
	if err := r.applyTransport(ctx, set.Routes(), deleted.Namespace, gatewayName, gatewayNamespace, modelOwners, providerOwners); err != nil {
		return fmt.Errorf("rebuild transport after ExternalModel deletion: %w", err)
	}
	if err := r.cleanupTransport(ctx, deleted.Namespace, set.Routes()); err != nil {
		return err
	}
	pub, err := publisher.New(r.Client, publisher.Config{Namespace: deleted.Namespace, Name: r.ConfigMap})
	if err != nil {
		return err
	}
	publish := r.PublishOverlay
	if publish == nil {
		publish = pub.Publish
	}
	if _, err := publish(ctx, set, envelope.Scope{
		Network: r.Network, Gateway: gatewayName, Namespace: deleted.Namespace, LocalSite: r.localSite(),
	}, envelope.Options{
		KnownClusters: r.KnownClusters, SourceUID: string(modelPtrs[0].UID), ProducerVersion: "dev",
	}); err != nil {
		return fmt.Errorf("publish remaining overlay after ExternalModel deletion: %w", err)
	}
	return r.removeExternalModelFinalizer(ctx, deleted)
}

func (r *Reconciler) removeExternalModelFinalizer(ctx context.Context, model *v1alpha1.ExternalModel) error {
	if !controllerutil.RemoveFinalizer(model, externalModelFinalizer) {
		return nil
	}
	if err := r.Update(ctx, model); err != nil {
		return fmt.Errorf("remove ExternalModel cleanup finalizer: %w", err)
	}
	return nil
}

func (r *Reconciler) cleanupTransport(ctx context.Context, namespace string, routes []resolver.Route) error {
	providers := map[string]bool{}
	models := map[string]bool{}
	for _, route := range routes {
		providers[route.Provider] = true
		models[route.Model] = true
	}
	resources := []struct {
		kind, group, version, label string
		keep                        map[string]bool
	}{
		{"Service", "", "v1", "inference.opendatahub.io/external-provider", providers},
		{"ServiceEntry", "networking.istio.io", "v1", "inference.opendatahub.io/external-provider", providers},
		{"DestinationRule", "networking.istio.io", "v1", "inference.opendatahub.io/external-provider", providers},
		{"HTTPRoute", "gateway.networking.k8s.io", "v1", "inference.opendatahub.io/external-model", models},
	}
	for _, resource := range resources {
		list := &unstructured.UnstructuredList{}
		list.SetGroupVersionKind(schema.GroupVersionKind{Group: resource.group, Version: resource.version, Kind: resource.kind + "List"})
		if err := r.List(ctx, list, client.InNamespace(namespace), client.MatchingLabels{"app.kubernetes.io/managed-by": "ai-gateway-controller"}); err != nil {
			return fmt.Errorf("list stale %s resources: %w", resource.kind, err)
		}
		for i := range list.Items {
			name := list.Items[i].GetLabels()[resource.label]
			if name != "" && !resource.keep[name] {
				if err := r.Delete(ctx, &list.Items[i]); client.IgnoreNotFound(err) != nil {
					return fmt.Errorf("delete stale %s %s/%s: %w", resource.kind, namespace, list.Items[i].GetName(), err)
				}
			}
		}
	}
	return nil
}

// cleanupOverlay removes only the routing ConfigMap owned by this controller
// when a namespace leaves Praxis selection. It is intentionally label-gated:
// the ConfigMap is shared by models in one tenant namespace, but resources in
// other namespaces and any non-controller ConfigMap are never touched.
func (r *Reconciler) cleanupOverlay(ctx context.Context, namespace string) error {
	var cm corev1.ConfigMap
	key := client.ObjectKey{Namespace: namespace, Name: r.configMapName()}
	if err := r.Get(ctx, key, &cm); err != nil {
		return client.IgnoreNotFound(err)
	}
	if cm.Labels["app.kubernetes.io/managed-by"] != "ai-gateway-controller" {
		return nil
	}
	return client.IgnoreNotFound(r.Delete(ctx, &cm))
}

func (r *Reconciler) praxisTenantForNamespace(ctx context.Context, namespace string) (*unstructured.Unstructured, bool, error) {
	var tenants unstructured.UnstructuredList
	tenants.SetGroupVersionKind(tenant.AITenantGVK.GroupVersion().WithKind("AITenantList"))
	if err := r.List(ctx, &tenants); err != nil {
		return nil, false, fmt.Errorf("list AITenants: %w", err)
	}
	for i := range tenants.Items {
		ait := &tenants.Items[i]
		tenantNamespace, _, _ := unstructured.NestedString(ait.Object, "status", "tenantNamespace")
		if tenantNamespace == "" {
			tenantNamespace = ait.GetNamespace()
		}
		if tenantNamespace == namespace && tenant.UsesPraxis(ait) {
			return ait, true, nil
		}
	}
	return nil, false, nil
}

func (r *Reconciler) validateProvider(ctx context.Context, p *v1alpha1.ExternalProvider) error {
	authType := strings.ToLower(strings.TrimSpace(p.Spec.Auth.Type))
	if authType != "apikey" {
		if authType == "" {
			return errors.New("auth.type is required; supported strategy is apikey")
		}
		return fmt.Errorf("unsupported authentication strategy %q; only apikey is supported", p.Spec.Auth.Type)
	}
	if p.Spec.Auth.SecretRef.Name == "" {
		return errors.New("auth.secretRef.name is required")
	}
	if r.APIReader == nil {
		return errors.New("APIReader is required for credential Secret reads")
	}
	var secret corev1.Secret
	if err := r.APIReader.Get(ctx, client.ObjectKey{Namespace: p.Namespace, Name: p.Spec.Auth.SecretRef.Name}, &secret); err != nil {
		return fmt.Errorf("credential Secret %s/%s: %w", p.Namespace, p.Spec.Auth.SecretRef.Name, err)
	}
	if _, ok := secret.Data["api-key"]; !ok {
		return fmt.Errorf("credential Secret %s/%s is missing key api-key", p.Namespace, p.Spec.Auth.SecretRef.Name)
	}
	return nil
}

func (r *Reconciler) namespaceAllowed(namespace string) bool {
	return namespace != "" && (r.Namespace == "" || r.Namespace == namespace)
}

func (r *Reconciler) applyTransport(ctx context.Context, routes []resolver.Route, modelNamespace, gatewayName,
	gatewayNamespace string, modelOwners map[string]*v1alpha1.ExternalModel,
	providerOwners map[string]*v1alpha1.ExternalProvider) error {
	resources := make([]unstructured.Unstructured, 0, len(routes)*3+len(routes))
	seen := map[string]bool{}
	for _, route := range routes {
		for _, obj := range []unstructured.Unstructured{
			providerService(route, modelNamespace),
			providerServiceEntry(route, modelNamespace),
			providerDestinationRule(route, modelNamespace),
		} {
			if owner := providerOwners[route.Provider]; owner != nil {
				setOwnerReference(&obj, owner)
			}
			key := obj.GetKind() + "/" + obj.GetNamespace() + "/" + obj.GetName()
			if !seen[key] {
				resources = append(resources, obj)
				seen[key] = true
			}
		}
	}
	models := map[string]resolver.Route{}
	for _, route := range routes {
		models[route.Model] = route
	}
	for _, route := range models {
		obj := modelHTTPRoute(route, modelNamespace, gatewayName, gatewayNamespace)
		if owner := modelOwners[route.Model]; owner != nil {
			setOwnerReference(&obj, owner)
		}
		key := obj.GetKind() + "/" + obj.GetNamespace() + "/" + obj.GetName()
		if !seen[key] {
			resources = append(resources, obj)
		}
	}
	for _, resource := range resources {
		if r.ApplyResource != nil {
			if err := r.ApplyResource(ctx, r.Client, resource); err != nil {
				return err
			}
			continue
		}
		if err := render.Apply(ctx, r.Client, []unstructured.Unstructured{resource}); err != nil {
			return err
		}
	}
	return nil
}

func setOwnerReference(obj *unstructured.Unstructured, owner client.Object) {
	uid := owner.GetUID()
	if uid == "" {
		return
	}
	controller := true
	blockOwnerDeletion := true
	apiVersion, kind := v1alpha1.GroupVersion.String(), "ExternalModel"
	if _, ok := owner.(*v1alpha1.ExternalProvider); ok {
		kind = "ExternalProvider"
	}
	obj.SetOwnerReferences([]metav1.OwnerReference{{
		APIVersion: apiVersion,
		Kind:       kind,
		Name:       owner.GetName(), UID: uid,
		Controller: &controller, BlockOwnerDeletion: &blockOwnerDeletion,
	}})
}

func (r *Reconciler) updateProviderStatus(ctx context.Context, p *v1alpha1.ExternalProvider, ready bool, reason, message string) error {
	old := p.DeepCopy()
	p.Status.ObservedGeneration = p.Generation
	if ready {
		p.Status.Phase = resolver.PhaseReady
	} else {
		p.Status.Phase = "Failed"
	}
	setCondition(&p.Status.Conditions, conditionReady, boolStatus(ready), reason, message)
	if equality.Semantic.DeepEqual(old.Status, p.Status) {
		return nil
	}
	if err := r.Status().Patch(ctx, p, client.MergeFrom(old)); err != nil {
		if !apierrors.IsConflict(err) {
			r.Log.Error(err, "update provider status", "provider", p.Name)
		}
		return fmt.Errorf("update provider status %s/%s: %w", p.Namespace, p.Name, err)
	}
	return nil
}

func (r *Reconciler) updateModelStatus(ctx context.Context, m *v1alpha1.ExternalModel, ready bool, reason, message string, env *envelope.Envelope) error {
	old := m.DeepCopy()
	m.Status.ObservedGeneration = m.Generation
	if ready {
		m.Status.Phase = resolver.PhaseReady
		m.Status.HTTPRouteName = modelRouteName(m.Name)
		if env != nil {
			m.Status.OverlayDigest = env.Revision.Value
			m.Status.OverlayGeneration = env.Provenance.SourceGeneration
			setCondition(&m.Status.Conditions, conditionOverlayDistributed, metav1.ConditionTrue, reasonReconciled, message)
		}
	} else {
		m.Status.Phase = "Failed"
		setCondition(&m.Status.Conditions, conditionOverlayDistributed, metav1.ConditionFalse, reason, message)
	}
	setCondition(&m.Status.Conditions, conditionReady, boolStatus(ready), reason, message)
	if equality.Semantic.DeepEqual(old.Status, m.Status) {
		return nil
	}
	if err := r.Status().Patch(ctx, m, client.MergeFrom(old)); err != nil {
		if !apierrors.IsConflict(err) {
			r.Log.Error(err, "update model status", "model", m.Name)
		}
		return fmt.Errorf("update model status %s/%s: %w", m.Namespace, m.Name, err)
	}
	return nil
}

func setCondition(conditions *[]metav1.Condition, typ string, status metav1.ConditionStatus, reason, message string) {
	apiMeta.SetStatusCondition(conditions, metav1.Condition{Type: typ, Status: status, Reason: reason, Message: message})
}

func boolStatus(ready bool) metav1.ConditionStatus {
	if ready {
		return metav1.ConditionTrue
	}
	return metav1.ConditionFalse
}
func modelRouteName(model string) string {
	return modelRoutePrefix + strings.ToLower(strings.ReplaceAll(model, "/", "-"))
}
func (r *Reconciler) gatewayName() string {
	if r.GatewayName != "" {
		return r.GatewayName
	}
	return "maas-default-gateway"
}
func (r *Reconciler) gatewayNamespace() string {
	if r.GatewayNamespace != "" {
		return r.GatewayNamespace
	}
	return r.Namespace
}
func (r *Reconciler) configMapName() string {
	if r.ConfigMap != "" {
		return r.ConfigMap
	}
	return publisher.DefaultName
}
func (r *Reconciler) localSite() string {
	if r.LocalSite != "" {
		return r.LocalSite
	}
	return "local"
}
func metadata(name, namespace string) map[string]any {
	return map[string]any{"name": name, "namespace": namespace, "labels": map[string]any{"app.kubernetes.io/managed-by": "ai-gateway-controller"}}
}

func labelledMetadata(name, namespace, key, value string) map[string]any {
	m := metadata(name, namespace)
	labels := map[string]any{"app.kubernetes.io/managed-by": "ai-gateway-controller", key: value}
	m["labels"] = labels
	return m
}

func providerService(route resolver.Route, ns string) unstructured.Unstructured {
	return unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Service",
		"metadata": labelledMetadata(providerServicePrefix+route.Provider, ns, "inference.opendatahub.io/external-provider", route.Provider),
		"spec": map[string]any{
			"type": "ExternalName", "externalName": route.Endpoint,
			"ports": []any{map[string]any{"name": "https", "port": int64(443), "targetPort": int64(443)}},
		},
	}}
}
func providerServiceEntry(route resolver.Route, ns string) unstructured.Unstructured {
	return unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "networking.istio.io/v1", "kind": "ServiceEntry",
		"metadata": labelledMetadata(providerServicePrefix+route.Provider, ns, "inference.opendatahub.io/external-provider", route.Provider),
		"spec": map[string]any{
			"hosts": []any{route.Endpoint}, "location": "MESH_EXTERNAL", "resolution": "DNS",
			"ports": []any{map[string]any{"name": "https", "number": int64(443), "protocol": "HTTPS"}},
		},
	}}
}
func providerDestinationRule(route resolver.Route, ns string) unstructured.Unstructured {
	return unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "networking.istio.io/v1", "kind": "DestinationRule",
		"metadata": labelledMetadata(providerServicePrefix+route.Provider, ns, "inference.opendatahub.io/external-provider", route.Provider),
		"spec": map[string]any{
			"host":          route.Endpoint,
			"trafficPolicy": map[string]any{"tls": map[string]any{"mode": "SIMPLE", "sni": route.Endpoint}},
		},
	}}
}
func modelHTTPRoute(route resolver.Route, ns, gateway, gatewayNS string) unstructured.Unstructured {
	parent := map[string]any{"name": gateway}
	if gatewayNS != "" && gatewayNS != ns {
		parent["namespace"] = gatewayNS
	}
	path := "/" + ns + "/" + route.ClientName
	backend := providerServicePrefix + route.Provider
	return unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
		"metadata": labelledMetadata(modelRouteName(route.Model), ns, "inference.opendatahub.io/external-model", route.Model),
		"spec": map[string]any{
			"parentRefs": []any{parent},
			"rules": []any{
				map[string]any{
					"matches":     []any{map[string]any{"path": map[string]any{"type": "PathPrefix", "value": path}}},
					"backendRefs": []any{map[string]any{"name": backend, "port": int64(443)}},
					"filters":     []any{map[string]any{"type": "URLRewrite", "urlRewrite": map[string]any{"path": map[string]any{"type": "ReplacePrefixMatch", "replacePrefixMatch": "/"}}}},
					"timeouts":    map[string]any{"request": "300s"},
				},
				map[string]any{
					// This body-routing rule intentionally matches the model header
					// on any Gateway path. ExtProc extracts the client model identity
					// from the request body/header, while the path rule above preserves
					// the normal URL-based contract and rewrite.
					"matches":     []any{map[string]any{"headers": []any{map[string]any{"name": "X-Gateway-Model-Name", "type": "Exact", "value": route.ClientName}}}},
					"backendRefs": []any{map[string]any{"name": backend, "port": int64(443)}},
					"timeouts":    map[string]any{"request": "300s"},
				},
			},
		},
	}}
}

var _ client.Object = (*v1alpha1.ExternalModel)(nil)
var _ client.Object = (*v1alpha1.ExternalProvider)(nil)
