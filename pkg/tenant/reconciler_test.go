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
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/envelope"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/resolver"
)

// manifestPath points at the vendored (committed) praxis-extproc overlay,
// mirroring pkg/render's own tests. This package is a sibling of
// pkg/render, so the relative depth to the repo root is the same.
const manifestPath = "../../config/manifests/praxis-extproc/overlays/odh"

// aitenantSchemeForTests registers the AITenant GVK (and its List kind)
// with a bare scheme so the fake client can Get/List/Patch it as
// unstructured without depending on maas-controller's Go types.
func aitenantSchemeForTests() *runtime.Scheme {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	scheme.AddKnownTypeWithName(AITenantGVK, &unstructured.Unstructured{})
	listGVK := AITenantGVK.GroupVersion().WithKind(AITenantGVK.Kind + "List")
	scheme.AddKnownTypeWithName(listGVK, &unstructured.UnstructuredList{})
	scheme.AddKnownTypeWithName(MaasTenantConfigGVK, &unstructured.Unstructured{})
	return scheme
}

// newAITenant builds an unstructured AITenant fixture. payloadProcessingType
// set to "" omits MaaS's selector annotation; phase set to ""
// omits status.phase.
func newAITenant(name, payloadProcessingType, phase, gatewayName, gatewayNamespace string) *unstructured.Unstructured {
	u := NewAITenant()
	u.SetName(name)
	if payloadProcessingType != "" {
		u.SetAnnotations(map[string]string{AnnotationPayloadProcessingType: payloadProcessingType})
	}
	status := map[string]any{}
	if phase != "" {
		status["phase"] = phase
	}
	if gatewayName != "" || gatewayNamespace != "" {
		status["gatewayRef"] = map[string]any{"name": gatewayName, "namespace": gatewayNamespace}
		status["tenantNamespace"] = gatewayNamespace
	}
	u.Object["status"] = status
	return u
}

func withIPPMigrationCleanupComplete(u *unstructured.Unstructured) *unstructured.Unstructured {
	annotations := u.GetAnnotations()
	if annotations == nil {
		annotations = map[string]string{}
	}
	annotations[AnnotationIPPMigrationCleanupComplete] = "true"
	u.SetAnnotations(annotations)
	return u
}

func readyMaaSTenantConfig(namespace string) *unstructured.Unstructured {
	config := maasTenantConfigObject()
	config.SetName(MaasTenantConfigName)
	config.SetNamespace(namespace)
	config.SetAnnotations(map[string]string{AnnotationIPPMigrationCleanupComplete: "true"})
	return config
}

// recorder captures what Reconciler did against the fake client, split by
// target so tests can assert on praxis-extproc resource applies, AITenant
// finalizer maintenance, and cleanup deletes independently.
type recorder struct {
	mu                 sync.Mutex
	resourcePatchNames []string
	aitenantPatches    int
	deletedNames       []string
}

func (r *recorder) funcs() interceptor.Funcs {
	return interceptor.Funcs{
		// AITenant's own finalizer add/remove uses a real (non-SSA) merge
		// patch, which the fake client supports natively, so delegate to
		// make the change observable on a follow-up Get. Praxis-extproc
		// resource applies use client.Apply (SSA), which the fake client's
		// tracker does not implement, so those are recorded and
		// short-circuited instead (mirrors the original render-only test
		// style).
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch, opts ...client.PatchOption) error {
			if obj.GetObjectKind().GroupVersionKind().Kind == AITenantGVK.Kind {
				r.mu.Lock()
				r.aitenantPatches++
				r.mu.Unlock()
				return c.Patch(ctx, obj, patch, opts...)
			}
			r.mu.Lock()
			r.resourcePatchNames = append(r.resourcePatchNames, obj.GetName())
			r.mu.Unlock()
			return nil
		},
		Delete: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.DeleteOption) error {
			r.mu.Lock()
			r.deletedNames = append(r.deletedNames, obj.GetName())
			r.mu.Unlock()
			return c.Delete(ctx, obj, opts...)
		},
	}
}

func (r *recorder) persistingFuncs() interceptor.Funcs {
	return interceptor.Funcs{
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch, opts ...client.PatchOption) error {
			if obj.GetObjectKind().GroupVersionKind().Kind == AITenantGVK.Kind {
				r.mu.Lock()
				r.aitenantPatches++
				r.mu.Unlock()
				return c.Patch(ctx, obj, patch, opts...)
			}
			// The reconciliation path also applies shared RBAC objects. The
			// fake client's SSA tracker cannot persist those unstructured
			// cluster-scoped objects, and they are not part of these tests'
			// assertions. Persist only the namespaced workload/configuration
			// objects needed to inspect the rollout gate.
			switch obj.GetObjectKind().GroupVersionKind().Kind {
			case "ConfigMap", "Deployment", "Service", "ServiceAccount":
			default:
				return nil
			}
			r.mu.Lock()
			r.resourcePatchNames = append(r.resourcePatchNames, obj.GetName())
			r.mu.Unlock()
			if err := c.Create(ctx, obj); err == nil {
				return nil
			} else if !apierrors.IsAlreadyExists(err) {
				return err
			}
			current, ok := obj.DeepCopyObject().(client.Object)
			if !ok {
				return fmt.Errorf("%T is not a client object", obj)
			}
			if err := c.Get(ctx, client.ObjectKey{Namespace: obj.GetNamespace(), Name: obj.GetName()}, current); err != nil {
				return err
			}
			obj.SetResourceVersion(current.GetResourceVersion())
			return c.Update(ctx, obj)
		},
	}
}

func (r *recorder) snapshot() (resourcePatchNames []string, aitenantPatches int, deletedNames []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.resourcePatchNames...), r.aitenantPatches, append([]string(nil), r.deletedNames...)
}

func requireManifests(t *testing.T) {
	t.Helper()
	if _, err := render.Build(manifestPath); err != nil {
		t.Skipf("vendored manifests not present at %s; run hack/scripts/get-manifests.sh first: %v", manifestPath, err)
	}
}

func validRoutingOverlay(t *testing.T, namespace string) *corev1.ConfigMap {
	t.Helper()
	env, err := envelope.Render(&resolver.ResolvedRouteSet{}, envelope.Scope{
		Network: "external-model", Gateway: "my-gateway", Namespace: namespace, LocalSite: "local",
	}, envelope.Revision{}, envelope.Options{SourceUID: "tenant-uid"})
	if err != nil {
		t.Fatalf("Render bootstrap overlay: %v", err)
	}
	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal bootstrap overlay: %v", err)
	}
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      praxisOverlayName,
			Namespace: namespace,
			Labels:    map[string]string{managedByLabel: render.FieldOwner},
		},
		Data: map[string]string{praxisOverlayDataKey: string(raw)},
	}
}

func routingOverlayForProvider(t *testing.T, namespace, provider string) *corev1.ConfigMap {
	t.Helper()
	env, err := envelope.Render(&resolver.ResolvedRouteSet{Models: []resolver.ModelRoutes{{
		ModelRef: namespace + "/demo-model",
		Routes: []resolver.Route{{
			Model: "demo-model", ClientName: "demo", Namespace: namespace,
			Provider: provider, Cluster: "provider-" + provider,
			ProviderType: "openai", Endpoint: provider + ".example.com",
			TargetModel: "demo", APIFormat: "openai-chat", Path: "/v1/chat/completions",
			Weight: 1, AuthType: "apikey", SecretName: "credentials", SecretKey: "api-key",
		}},
	}}}, envelope.Scope{
		Network: "external-model", Gateway: "my-gateway", Namespace: namespace, LocalSite: "local",
	}, envelope.Revision{}, envelope.Options{SourceUID: "tenant-uid"})
	if err != nil {
		t.Fatalf("Render provider overlay: %v", err)
	}
	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal provider overlay: %v", err)
	}
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name: praxisOverlayName, Namespace: namespace,
			Labels: map[string]string{managedByLabel: render.FieldOwner},
		},
		Data: map[string]string{praxisOverlayDataKey: string(raw)},
	}
}

func TestReconcileWaitsForMaaSIPPReleaseBeforeRenderingPraxisResources(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.persistingFuncs()).Build()
	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute}

	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != notReadyRequeueInterval {
		t.Fatalf("RequeueAfter = %v, want %v", res.RequeueAfter, notReadyRequeueInterval)
	}
	var deployment unstructured.Unstructured
	deployment.SetGroupVersionKind(gvkDeployment)
	if err := fakeClient.Get(context.Background(), client.ObjectKey{Namespace: "tenant-ns", Name: "praxis-redteam"}, &deployment); !apierrors.IsNotFound(err) {
		t.Fatalf("Praxis Deployment lookup = %v, want NotFound", err)
	}
}

func TestIPPResourcesReleasedAcceptsMaaSStatusCondition(t *testing.T) {
	scheme := aitenantSchemeForTests()
	config := maasTenantConfigObject()
	config.SetName(MaasTenantConfigName)
	config.SetNamespace("tenant-ns")
	config.Object["status"] = map[string]any{"conditions": []any{map[string]any{
		"type": IPPResourcesReleasedCondition, "status": "True",
	}}}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(config).Build()
	r := &Reconciler{Client: fakeClient}

	released, reason, err := r.ippResourcesReleased(context.Background(), "tenant-ns")
	if err != nil {
		t.Fatalf("ippResourcesReleased: %v", err)
	}
	if !released || !strings.Contains(reason, "condition") {
		t.Fatalf("ippResourcesReleased = %t, %q; want true with condition reason", released, reason)
	}
}

func TestReconcileAppliesExtProcWithoutStandalonePraxis(t *testing.T) {
	requireManifests(t)
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant, readyMaaSTenantConfig("tenant-ns")).WithInterceptorFuncs(rec.persistingFuncs()).Build()
	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", MaaSAPIRouteNameBase: "maas-api-route", ResyncInterval: time.Minute}

	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != time.Minute {
		t.Fatalf("RequeueAfter = %v, want one-minute resync", res.RequeueAfter)
	}
	var extproc unstructured.Unstructured
	extproc.SetGroupVersionKind(gvkDeployment)
	if err := fakeClient.Get(context.Background(), client.ObjectKey{Namespace: "tenant-ns", Name: "payload-processing-redteam"}, &extproc); err != nil {
		t.Fatalf("payload-processing Deployment missing: %v", err)
	}
	var praxis unstructured.Unstructured
	praxis.SetGroupVersionKind(gvkDeployment)
	if err := fakeClient.Get(context.Background(), client.ObjectKey{Namespace: "tenant-ns", Name: "praxis-redteam"}, &praxis); !apierrors.IsNotFound(err) {
		t.Fatalf("standalone Praxis Deployment lookup = %v, want NotFound", err)
	}
}

func TestReconcileDeletesLeftoverStandalonePraxis(t *testing.T) {
	requireManifests(t)
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns")
	leftover := &unstructured.Unstructured{}
	leftover.SetGroupVersionKind(gvkDeployment)
	leftover.SetName("praxis-redteam")
	leftover.SetNamespace("tenant-ns")
	leftover.SetLabels(map[string]string{LabelManagedBy: ManagedByAIGatewayController})
	leftover.Object["spec"] = map[string]any{"replicas": int64(1)}
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant, readyMaaSTenantConfig("tenant-ns"), leftover).WithInterceptorFuncs(rec.persistingFuncs()).Build()
	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", MaaSAPIRouteNameBase: "maas-api-route", ResyncInterval: time.Minute}

	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}}); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	var praxis unstructured.Unstructured
	praxis.SetGroupVersionKind(gvkDeployment)
	if err := fakeClient.Get(context.Background(), client.ObjectKey{Namespace: "tenant-ns", Name: "praxis-redteam"}, &praxis); !apierrors.IsNotFound(err) {
		t.Fatalf("leftover Praxis Deployment lookup = %v, want NotFound", err)
	}
}

func TestReconcileOmitsNetworkPolicyWhenExplicitlyConfigured(t *testing.T) {
	requireManifests(t)
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(
		aitenant, readyMaaSTenantConfig("tenant-ns"),
	).WithInterceptorFuncs(rec.funcs()).Build()
	r := &Reconciler{
		Client: fakeClient, ManifestPath: manifestPath, Image: "img",
		MaaSAPIRouteNameBase: "maas-api-route", ResyncInterval: time.Minute,
		SkipNetworkPolicy: true,
	}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}}); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	var policy unstructured.Unstructured
	policy.SetGroupVersionKind(gvkNetworkPolicy)
	if err := fakeClient.Get(context.Background(), client.ObjectKey{Namespace: "tenant-ns", Name: "payload-processing-redteam"}, &policy); !apierrors.IsNotFound(err) {
		t.Fatalf("NetworkPolicy lookup = %v, want NotFound", err)
	}
}

func TestRoutingOverlayReadyDoesNotRequireDisabledProvider(t *testing.T) {
	const namespace = "tenant-ns"
	overlay := routingOverlayForProvider(t, namespace, "provider-a")
	fakeClient := fake.NewClientBuilder().WithScheme(aitenantSchemeForTests()).WithObjects(overlay).Build()
	r := &Reconciler{Client: fakeClient}

	ready, reason, err := r.routingOverlayReady(context.Background(), namespace, map[string]bool{"provider-a": true})
	if err != nil {
		t.Fatalf("routingOverlayReady: %v", err)
	}
	if !ready || reason == "" {
		t.Fatalf("routingOverlayReady = %t, %q; want ready", ready, reason)
	}
}

func TestTenantsForNamespaceMapsExternalModelChanges(t *testing.T) {
	ait := newAITenant("tenant", PayloadProcessingBackendPraxis, AITenantPhaseActive, "gateway", "tenant-a")
	ait.SetNamespace("ai-tenants")
	model := &unstructured.Unstructured{}
	model.SetGroupVersionKind(schema.GroupVersionKind{Group: "inference.opendatahub.io", Version: "v1alpha1", Kind: "ExternalModel"})
	model.SetName("demo")
	model.SetNamespace("tenant-a")
	fakeClient := fake.NewClientBuilder().WithScheme(aitenantSchemeForTests()).WithObjects(ait, model).Build()
	r := &Reconciler{Client: fakeClient}
	requests := r.tenantsForNamespace(context.Background(), model)
	want := ctrl.Request{NamespacedName: client.ObjectKeyFromObject(ait)}
	if len(requests) != 1 || requests[0] != want {
		t.Fatalf("ExternalModel event enqueued %#v, want %#v", requests, want)
	}
}

func TestReconcileSkipsWhenAITenantNotFound(t *testing.T) {
	scheme := aitenantSchemeForTests()
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "missing"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != 0 {
		t.Fatalf("RequeueAfter = %v, want 0 for a deleted/missing AITenant", res.RequeueAfter)
	}
	patched, aitenantPatches, deleted := rec.snapshot()
	if len(patched) != 0 || aitenantPatches != 0 || len(deleted) != 0 {
		t.Fatalf("expected no writes, got patched=%v aitenantPatches=%d deleted=%v", patched, aitenantPatches, deleted)
	}
}

func TestWaitForForeignOwnershipDoesNotTakeOverExistingObject(t *testing.T) {
	deployment := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]any{
			"name":      "payload-processing-transition",
			"namespace": "maas-system",
			"labels": map[string]any{
				"app.kubernetes.io/managed-by": "ipp-external-model-reconciler",
			},
		},
	}}
	deployment.SetGroupVersionKind(schema.GroupVersionKind{Group: "apps", Version: "v1", Kind: "Deployment"})
	fakeClient := fake.NewClientBuilder().WithScheme(aitenantSchemeForTests()).WithObjects(deployment).Build()
	r := &Reconciler{Client: fakeClient}
	desired := deployment.DeepCopy()
	desired.SetLabels(map[string]string{"app.kubernetes.io/managed-by": render.FieldOwner})
	if err := r.waitForForeignOwnership(context.Background(), []unstructured.Unstructured{*desired}); err == nil {
		t.Fatal("waitForForeignOwnership accepted an object owned by the IPP reconciler")
	}
}

func TestWaitForForeignOwnershipAcceptsReleasedPluginConfigMap(t *testing.T) {
	configMap := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1",
		"kind":       "ConfigMap",
		"metadata": map[string]any{
			"name":      PayloadProcessingPluginsConfigMapForTenant("transition"),
			"namespace": "maas-system",
			"annotations": map[string]any{
				"opendatahub.io/managed": "false",
			},
		},
	}}
	configMap.SetGroupVersionKind(schema.GroupVersionKind{Version: "v1", Kind: "ConfigMap"})
	fakeClient := fake.NewClientBuilder().WithScheme(aitenantSchemeForTests()).WithObjects(configMap).Build()
	r := &Reconciler{Client: fakeClient}
	desired := configMap.DeepCopy()
	desired.SetAnnotations(nil)
	desired.SetLabels(map[string]string{"app.kubernetes.io/managed-by": render.FieldOwner})
	if err := r.waitForForeignOwnership(context.Background(), []unstructured.Unstructured{*desired}); err != nil {
		t.Fatalf("waitForForeignOwnership rejected the explicitly released plugin ConfigMap: %v", err)
	}
}

func TestWaitForForeignOwnershipDoesNotTreatOtherUnmanagedObjectsAsReleased(t *testing.T) {
	configMap := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1",
		"kind":       "ConfigMap",
		"metadata": map[string]any{
			"name":      "other-config",
			"namespace": "maas-system",
			"annotations": map[string]any{
				"opendatahub.io/managed": "false",
			},
		},
	}}
	configMap.SetGroupVersionKind(schema.GroupVersionKind{Version: "v1", Kind: "ConfigMap"})
	fakeClient := fake.NewClientBuilder().WithScheme(aitenantSchemeForTests()).WithObjects(configMap).Build()
	r := &Reconciler{Client: fakeClient}
	desired := configMap.DeepCopy()
	desired.SetAnnotations(nil)
	desired.SetLabels(map[string]string{"app.kubernetes.io/managed-by": render.FieldOwner})
	if err := r.waitForForeignOwnership(context.Background(), []unstructured.Unstructured{*desired}); err == nil {
		t.Fatal("waitForForeignOwnership accepted an unrelated unmanaged ConfigMap")
	}
}

func TestReconcileSkipsWhenNotUsingPraxis(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", "", "", "", "")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != 0 {
		t.Fatalf("RequeueAfter = %v, want 0 for a non-praxis tenant", res.RequeueAfter)
	}
	patched, aitenantPatches, deleted := rec.snapshot()
	if len(patched) != 0 || aitenantPatches != 0 || len(deleted) != 0 {
		t.Fatalf("expected no writes for a tenant that never used praxis, got patched=%v aitenantPatches=%d deleted=%v", patched, aitenantPatches, deleted)
	}
}

func TestReconcileAddsFinalizerAndRequeuesShortlyWhenNotActiveYet(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, "", "", "")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Hour}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != notReadyRequeueInterval {
		t.Fatalf("RequeueAfter = %v, want the short not-ready interval %v", res.RequeueAfter, notReadyRequeueInterval)
	}
	patched, aitenantPatches, deleted := rec.snapshot()
	if len(patched) != 0 || len(deleted) != 0 {
		t.Fatalf("expected no resource applies/deletes before Active, got patched=%v deleted=%v", patched, deleted)
	}
	if aitenantPatches != 1 {
		t.Fatalf("aitenantPatches = %d, want 1 (adding the cleanup finalizer)", aitenantPatches)
	}

	var got unstructured.Unstructured
	got.SetGroupVersionKind(AITenantGVK)
	if err := fakeClient.Get(context.Background(), client.ObjectKey{Name: "redteam"}, &got); err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !controllerutil.ContainsFinalizer(&got, PraxisCleanupFinalizer) {
		t.Fatal("expected PraxisCleanupFinalizer to be added even though the tenant is not Active yet")
	}
}

func TestReconcileRequeuesShortlyWhenActiveButGatewayRefNotReady(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "", "")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Hour}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != notReadyRequeueInterval {
		t.Fatalf("RequeueAfter = %v, want the short not-ready interval %v", res.RequeueAfter, notReadyRequeueInterval)
	}
	patched, _, deleted := rec.snapshot()
	if len(patched) != 0 || len(deleted) != 0 {
		t.Fatalf("expected no resource applies/deletes until status.gatewayRef is populated, got patched=%v deleted=%v", patched, deleted)
	}
}

func TestReconcileWaitsForMigrationMarkerBeforeApply(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns")
	delete(aitenant.GetAnnotations(), AnnotationIPPMigrationCleanupComplete)
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != notReadyRequeueInterval {
		t.Fatalf("RequeueAfter = %v, want %v", res.RequeueAfter, notReadyRequeueInterval)
	}
	names, _, _ := rec.snapshot()
	if len(names) != 0 {
		t.Fatalf("expected no praxis apply before migration marker, got %v", names)
	}
}

func TestReconcileWaitsForResolvedTenantNamespace(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "gateway-ns")
	unstructured.RemoveNestedField(aitenant.Object, "status", "tenantNamespace")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Hour}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != notReadyRequeueInterval {
		t.Fatalf("RequeueAfter = %v, want %v", res.RequeueAfter, notReadyRequeueInterval)
	}
	patched, _, deleted := rec.snapshot()
	if len(patched) != 0 || len(deleted) != 0 {
		t.Fatalf("expected no resource changes before status.tenantNamespace, got patched=%v deleted=%v", patched, deleted)
	}
}

func TestReconcileAppliesAndRequeuesResyncIntervalForNonDefaultTenant(t *testing.T) {
	requireManifests(t)
	scheme := aitenantSchemeForTests()
	aitenant := withIPPMigrationCleanupComplete(newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns"))
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant, readyMaaSTenantConfig("tenant-ns")).WithInterceptorFuncs(rec.funcs()).Build()

	const resync = 5 * time.Minute
	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", MaaSAPIRouteNameBase: "maas-api-route", ResyncInterval: resync}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != resync {
		t.Fatalf("RequeueAfter = %v, want ResyncInterval %v", res.RequeueAfter, resync)
	}

	names, aitenantPatches, _ := rec.snapshot()
	if len(names) == 0 {
		t.Fatal("resource patches = 0, want at least one applied resource")
	}
	if aitenantPatches != 1 {
		t.Fatalf("aitenantPatches = %d, want 1 (adding the cleanup finalizer)", aitenantPatches)
	}

	assertContains(t, names, "payload-processing-redteam")
	assertContains(t, names, "payload-pre-processing-redteam")
	assertContains(t, names, "payload-processing-plugins-redteam")
	assertContains(t, names, "payload-processing-reader-redteam")
	// The shared ClusterRole must NOT be tenant-suffixed.
	assertContains(t, names, "payload-processing-reader")
	for _, n := range names {
		if n == "payload-processing" || n == "payload-pre-processing" {
			t.Fatalf("found unsuffixed resource name %q while reconciling a non-default tenant", n)
		}
	}
}

func TestReconcileAppliesUnsuffixedNamesForDefaultTenant(t *testing.T) {
	requireManifests(t)
	scheme := aitenantSchemeForTests()
	aitenant := withIPPMigrationCleanupComplete(newAITenant(DefaultAITenantName, PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "openshift-ingress"))
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant, readyMaaSTenantConfig("openshift-ingress")).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", MaaSAPIRouteNameBase: "maas-api-route", ResyncInterval: time.Minute}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: DefaultAITenantName}}); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}

	names, _, _ := rec.snapshot()
	assertContains(t, names, "payload-processing")
	assertContains(t, names, "payload-pre-processing")
	assertContains(t, names, "payload-processing-plugins")
	assertContains(t, names, "payload-processing-reader")
}

func assertContains(t *testing.T, haystack []string, want string) {
	t.Helper()
	for _, v := range haystack {
		if v == want {
			return
		}
	}
	t.Fatalf("expected %q among applied resource names, got %v", want, haystack)
}

// withFinalizer adds PraxisCleanupFinalizer to a fixture, mirroring an
// AITenant this controller had already opted into praxis for on a
// previous reconcile.
func withFinalizer(u *unstructured.Unstructured) *unstructured.Unstructured {
	controllerutil.AddFinalizer(u, PraxisCleanupFinalizer)
	return u
}

func expectedCleanupNames(tenantID string) []string {
	return []string{
		PayloadProcessingDeploymentName(tenantID),
		PayloadPreProcessingDeploymentName(tenantID),
		PayloadProcessingServiceName(tenantID),
		PayloadPreProcessingServiceName(tenantID),
		PayloadProcessingPluginsConfigMapForTenant(tenantID),
		PayloadProcessingServiceAccountName(tenantID),
		PayloadProcessingNetworkPolicyName(tenantID),
		PayloadProcessingEnvoyFilterName(tenantID),
		PayloadProcessingReaderClusterRoleBindingNameForTenant(tenantID),
	}
}

func seedPraxisOwnedForCleanup(tenantID, namespace string) []client.Object {
	setManager := func(u *unstructured.Unstructured) client.Object {
		u.SetLabels(map[string]string{LabelManagedBy: ManagedByAIGatewayController})
		return u
	}
	mk := func(gvk schema.GroupVersionKind, name, ns string) client.Object {
		u := &unstructured.Unstructured{}
		u.SetGroupVersionKind(gvk)
		u.SetName(name)
		u.SetNamespace(ns)
		return setManager(u)
	}
	return []client.Object{
		mk(gvkDeployment, PayloadProcessingDeploymentName(tenantID), namespace),
		mk(gvkDeployment, PayloadPreProcessingDeploymentName(tenantID), namespace),
		mk(gvkService, PayloadProcessingServiceName(tenantID), namespace),
		mk(gvkService, PayloadPreProcessingServiceName(tenantID), namespace),
		mk(gvkConfigMap, PayloadProcessingPluginsConfigMapForTenant(tenantID), namespace),
		mk(gvkServiceAccount, PayloadProcessingServiceAccountName(tenantID), namespace),
		mk(gvkNetworkPolicy, PayloadProcessingNetworkPolicyName(tenantID), namespace),
		mk(gvkEnvoyFilter, PayloadProcessingEnvoyFilterName(tenantID), namespace),
		mk(gvkDestinationRule, PayloadProcessingServiceName(tenantID), namespace),
		mk(gvkDestinationRule, PayloadPreProcessingServiceName(tenantID), namespace),
		mk(gvkClusterRoleBinding, PayloadProcessingReaderClusterRoleBindingNameForTenant(tenantID), ""),
	}
}

func TestReconcileCleansUpAndRemovesFinalizerWhenSwitchedAwayFromPraxis(t *testing.T) {
	scheme := aitenantSchemeForTests()
	// No AnnotationPayloadProcessingType: this tenant switched back to IPP
	// (or dropped the annotation), but our finalizer from when it was
	// praxis is still present.
	aitenant := withFinalizer(newAITenant("redteam", "", AITenantPhaseActive, "my-gateway", "tenant-ns"))
	rec := &recorder{}
	seed := seedPraxisOwnedForCleanup("redteam", "tenant-ns")
	objs := append([]client.Object{aitenant}, seed...)
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objs...).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != 0 {
		t.Fatalf("RequeueAfter = %v, want 0", res.RequeueAfter)
	}

	_, aitenantPatches, deleted := rec.snapshot()
	if aitenantPatches != 1 {
		t.Fatalf("aitenantPatches = %d, want 1 (removing the cleanup finalizer)", aitenantPatches)
	}
	for _, want := range expectedCleanupNames("redteam") {
		assertContains(t, deleted, want)
	}

	var got unstructured.Unstructured
	got.SetGroupVersionKind(AITenantGVK)
	if err := fakeClient.Get(context.Background(), client.ObjectKey{Name: "redteam"}, &got); err != nil {
		t.Fatalf("Get: %v", err)
	}
	if controllerutil.ContainsFinalizer(&got, PraxisCleanupFinalizer) {
		t.Fatal("expected PraxisCleanupFinalizer to be removed after switch-away cleanup")
	}
}

func TestReconcileCleanupSkipsMaaSOwnedResources(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := withFinalizer(newAITenant("redteam", "", AITenantPhaseActive, "my-gateway", "tenant-ns"))
	legacyDeploy := &unstructured.Unstructured{}
	legacyDeploy.SetGroupVersionKind(gvkDeployment)
	legacyDeploy.SetName(PayloadProcessingDeploymentName("redteam"))
	legacyDeploy.SetNamespace("tenant-ns")
	legacyDeploy.SetLabels(map[string]string{LabelManagedBy: maasControllerFieldOwner})

	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant, legacyDeploy).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}}); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}

	_, _, deleted := rec.snapshot()
	for _, name := range deleted {
		if name == PayloadProcessingDeploymentName("redteam") {
			t.Fatalf("should not delete maas-controller-owned %q, got deletes %v", name, deleted)
		}
	}
}

func TestReconcileCleanupRemovesPreviouslyOwnedNetworkPolicyWhenCreationIsSkipped(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := withFinalizer(newAITenant("redteam", "", AITenantPhaseActive, "my-gateway", "tenant-ns"))
	ownedPolicy := &unstructured.Unstructured{}
	ownedPolicy.SetGroupVersionKind(gvkNetworkPolicy)
	ownedPolicy.SetName(PayloadProcessingNetworkPolicyName("redteam"))
	ownedPolicy.SetNamespace("tenant-ns")
	ownedPolicy.SetLabels(map[string]string{LabelManagedBy: ManagedByAIGatewayController})
	foreignPolicy := ownedPolicy.DeepCopy()
	foreignPolicy.SetName("payload-processing-foreign")
	foreignPolicy.SetLabels(map[string]string{LabelManagedBy: "other-controller"})

	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant, ownedPolicy, foreignPolicy).WithInterceptorFuncs(rec.funcs()).Build()
	r := &Reconciler{Client: fakeClient, SkipNetworkPolicy: true}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}}); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}

	_, _, deleted := rec.snapshot()
	assertContains(t, deleted, PayloadProcessingNetworkPolicyName("redteam"))
	for _, name := range deleted {
		if name == foreignPolicy.GetName() {
			t.Fatalf("deleted foreign NetworkPolicy %q", name)
		}
	}
}

func TestReconcileSwitchAwayWithoutFinalizerIsNoop(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", "", AITenantPhaseActive, "my-gateway", "tenant-ns")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}}); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}

	_, aitenantPatches, deleted := rec.snapshot()
	if aitenantPatches != 0 || len(deleted) != 0 {
		t.Fatalf("expected no writes for a tenant that never had our finalizer, got aitenantPatches=%d deleted=%v", aitenantPatches, deleted)
	}
}

func TestReconcileDeleteCleansUpAndRemovesFinalizer(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := withFinalizer(newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns"))
	now := metav1.Now()
	aitenant.SetDeletionTimestamp(&now)
	rec := &recorder{}
	seed := seedPraxisOwnedForCleanup("redteam", "tenant-ns")
	objs := append([]client.Object{aitenant}, seed...)
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objs...).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute, DeletionTimeout: 10 * time.Minute}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if res.RequeueAfter != 0 {
		t.Fatalf("RequeueAfter = %v, want 0", res.RequeueAfter)
	}

	_, aitenantPatches, deleted := rec.snapshot()
	if aitenantPatches != 1 {
		t.Fatalf("aitenantPatches = %d, want 1 (removing the cleanup finalizer)", aitenantPatches)
	}
	for _, want := range expectedCleanupNames("redteam") {
		assertContains(t, deleted, want)
	}
}

func TestReconcileDeleteWithoutFinalizerIsNoop(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns")
	// A real object with a DeletionTimestamp but no finalizers at all
	// would already be gone; give it maas-controller's own (unrelated)
	// finalizer so it legitimately still exists without ours.
	aitenant.SetFinalizers([]string{"maas.opendatahub.io/aitenant-cleanup"})
	now := metav1.Now()
	aitenant.SetDeletionTimestamp(&now)
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}}); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}

	_, aitenantPatches, deleted := rec.snapshot()
	if aitenantPatches != 0 || len(deleted) != 0 {
		t.Fatalf("expected no writes when our finalizer was never set, got aitenantPatches=%d deleted=%v", aitenantPatches, deleted)
	}
}

func TestReconcileDeleteSkipsCleanupWhenGatewayRefNeverPopulated(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := withFinalizer(newAITenant("redteam", PayloadProcessingBackendPraxis, "", "", ""))
	now := metav1.Now()
	aitenant.SetDeletionTimestamp(&now)
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}}); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}

	_, aitenantPatches, deleted := rec.snapshot()
	if len(deleted) != 0 {
		t.Fatalf("expected no deletes when status.gatewayRef was never populated, got %v", deleted)
	}
	if aitenantPatches != 1 {
		t.Fatalf("aitenantPatches = %d, want 1 (removing the cleanup finalizer)", aitenantPatches)
	}
}

func TestReconcileDeleteForceRemovesFinalizerAfterDeletionTimeout(t *testing.T) {
	scheme := aitenantSchemeForTests()
	aitenant := withFinalizer(newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns"))
	past := metav1.NewTime(time.Now().Add(-time.Hour))
	aitenant.SetDeletionTimestamp(&past)
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

	r := &Reconciler{Client: fakeClient, ManifestPath: manifestPath, Image: "img", ResyncInterval: time.Minute, DeletionTimeout: 10 * time.Minute}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKey{Name: "redteam"}}); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}

	_, aitenantPatches, deleted := rec.snapshot()
	if len(deleted) != 0 {
		t.Fatalf("expected cleanup to be skipped once the deletion timeout is exceeded, got deletes %v", deleted)
	}
	if aitenantPatches != 1 {
		t.Fatalf("aitenantPatches = %d, want 1 (force-removing the cleanup finalizer)", aitenantPatches)
	}
}
