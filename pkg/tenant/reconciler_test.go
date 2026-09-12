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
	"sync"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
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
	scheme.AddKnownTypeWithName(AITenantGVK, &unstructured.Unstructured{})
	listGVK := AITenantGVK.GroupVersion().WithKind(AITenantGVK.Kind + "List")
	scheme.AddKnownTypeWithName(listGVK, &unstructured.UnstructuredList{})
	return scheme
}

// newAITenant builds an unstructured AITenant fixture. payloadProcessingType
// set to "" omits AnnotationPayloadProcessingType entirely; phase set to ""
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
	}
	u.Object["status"] = status
	return u
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

func TestReconcileAppliesAndRequeuesResyncIntervalForNonDefaultTenant(t *testing.T) {
	requireManifests(t)
	scheme := aitenantSchemeForTests()
	aitenant := newAITenant("redteam", PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "tenant-ns")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

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
	aitenant := newAITenant(DefaultAITenantName, PayloadProcessingBackendPraxis, AITenantPhaseActive, "my-gateway", "openshift-ingress")
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

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

func TestReconcileCleansUpAndRemovesFinalizerWhenSwitchedAwayFromPraxis(t *testing.T) {
	scheme := aitenantSchemeForTests()
	// No AnnotationPayloadProcessingType: this tenant switched back to IPP
	// (or dropped the annotation), but our finalizer from when it was
	// praxis is still present.
	aitenant := withFinalizer(newAITenant("redteam", "", AITenantPhaseActive, "my-gateway", "tenant-ns"))
	rec := &recorder{}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

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
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(aitenant).WithInterceptorFuncs(rec.funcs()).Build()

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
