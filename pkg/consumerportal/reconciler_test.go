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

package consumerportal

import (
	"context"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/go-logr/logr"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	netwv1 "k8s.io/api/networking/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/constants"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/tenant"
)

const (
	testTenantNamespace  = "models-as-a-service"
	testInfraNamespace   = "redhat-ai-gateway-infra"
	testAITenantNS       = "ai-tenants"
	testGatewayName      = "maas-default-gateway"
	testGatewayNamespace = "openshift-ingress"
	testHostname         = "maas.apps.example.com"
	testIssuer           = "https://keycloak.apps.example.com/realms/tenant-a"
	testManifestPath     = "../../config/manifests/consumer-portal/base"
)

func testScheme() *runtime.Scheme {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	_ = appsv1.AddToScheme(scheme)
	_ = netwv1.AddToScheme(scheme)
	for _, gvk := range []struct{ group, version, kind string }{
		{tenant.MaasTenantConfigGVK.Group, tenant.MaasTenantConfigGVK.Version, tenant.MaasTenantConfigGVK.Kind},
		{tenant.AITenantGVK.Group, tenant.AITenantGVK.Version, tenant.AITenantGVK.Kind},
		{gvkGateway.Group, gvkGateway.Version, gvkGateway.Kind},
	} {
		gv := tenant.AITenantGVK.GroupVersion()
		gv.Group, gv.Version = gvk.group, gvk.version
		scheme.AddKnownTypeWithName(gv.WithKind(gvk.kind), &unstructured.Unstructured{})
		scheme.AddKnownTypeWithName(gv.WithKind(gvk.kind+"List"), &unstructured.UnstructuredList{})
	}
	return scheme
}

func newMTC(tenantName, infraNamespace string) *unstructured.Unstructured {
	u := tenant.NewMaasTenantConfig()
	u.SetName(tenant.MaasTenantConfigInstanceName)
	u.SetNamespace(testTenantNamespace)
	u.SetLabels(map[string]string{
		tenant.LabelManagedByAITenant: "true",
		tenant.LabelTenantName:        tenantName,
	})
	u.SetAnnotations(map[string]string{
		tenant.AnnotationAITenantName:      tenantName,
		tenant.AnnotationAITenantNamespace: testAITenantNS,
	})
	if infraNamespace != "" {
		u.Object["status"] = map[string]any{"infraNamespace": infraNamespace}
	}
	return u
}

type aitenantOpts struct {
	notReady       bool
	issuer         string
	portalDisabled bool
}

func newAITenant(opts aitenantOpts) *unstructured.Unstructured {
	u := tenant.NewAITenant()
	u.SetName(tenant.DefaultAITenantName)
	u.SetNamespace(testAITenantNS)
	phase, ready := tenant.AITenantPhaseActive, "True"
	if opts.notReady {
		phase, ready = tenant.AITenantPhaseFailed, "False"
	}
	spec := map[string]any{}
	if opts.issuer != "" {
		spec["oidc"] = map[string]any{"issuerUrl": opts.issuer, "clientId": "test-client"}
	}
	if opts.portalDisabled {
		spec["consumerPortal"] = map[string]any{"enabled": false}
	}
	u.Object["spec"] = spec
	u.Object["status"] = map[string]any{
		"phase":           phase,
		"tenantNamespace": testTenantNamespace,
		"gatewayRef":      map[string]any{"name": testGatewayName, "namespace": testGatewayNamespace},
		"conditions": []any{map[string]any{
			"type":               tenant.AITenantConditionReady,
			"status":             ready,
			"observedGeneration": u.GetGeneration(),
		}},
	}
	return u
}

func newGateway(listeners ...map[string]any) *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(gvkGateway)
	u.SetName(testGatewayName)
	u.SetNamespace(testGatewayNamespace)
	items := make([]any, 0, len(listeners))
	for _, l := range listeners {
		items = append(items, l)
	}
	u.Object["spec"] = map[string]any{"listeners": items}
	return u
}

func httpsListener(hostname string) map[string]any {
	return map[string]any{"name": "https", "protocol": "HTTPS", "port": int64(443), "hostname": hostname}
}

func credentialsSecret() *corev1.Secret {
	return &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: CredentialsSecretName, Namespace: testInfraNamespace}}
}

func managedProxyDeployment() *appsv1.Deployment {
	return &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{
		Name:      AuthProxyName,
		Namespace: testInfraNamespace,
		Labels:    map[string]string{tenant.LabelManagedBy: tenant.ManagedByAIGatewayController},
	}}
}

// recorder short-circuits server-side apply (unsupported by the fake client)
// and records which kinds were applied, read, and deleted.
type recorder struct {
	mu      sync.Mutex
	applied []string
	gets    []string
	deleted []string
}

func (r *recorder) funcs() interceptor.Funcs {
	return interceptor.Funcs{
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch, opts ...client.PatchOption) error {
			if patch.Type() == types.ApplyPatchType {
				r.mu.Lock()
				r.applied = append(r.applied, obj.GetObjectKind().GroupVersionKind().Kind+"/"+obj.GetNamespace()+"/"+obj.GetName())
				r.mu.Unlock()
				return nil
			}
			return c.Patch(ctx, obj, patch, opts...)
		},
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			r.mu.Lock()
			r.gets = append(r.gets, obj.GetObjectKind().GroupVersionKind().Kind)
			r.mu.Unlock()
			return c.Get(ctx, key, obj, opts...)
		},
		Delete: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.DeleteOption) error {
			r.mu.Lock()
			r.deleted = append(r.deleted, obj.GetObjectKind().GroupVersionKind().Kind)
			r.mu.Unlock()
			return c.Delete(ctx, obj, opts...)
		},
	}
}

func newReconciler(t *testing.T, objects ...client.Object) (*Reconciler, *recorder) {
	t.Helper()
	rec := &recorder{}
	c := fake.NewClientBuilder().WithScheme(testScheme()).WithObjects(objects...).WithInterceptorFuncs(rec.funcs()).Build()
	return &Reconciler{
		Client:         c,
		APIReader:      c,
		Log:            logr.Discard(),
		ManifestPath:   testManifestPath,
		Image:          "quay.io/example/kube-auth-proxy:test",
		ResyncInterval: 5 * time.Minute,
	}, rec
}

func reconcileMTC(t *testing.T, r *Reconciler) ctrl.Result {
	t.Helper()
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{
		Namespace: testTenantNamespace, Name: tenant.MaasTenantConfigInstanceName,
	}})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	return res
}

func getMTC(t *testing.T, c client.Client) *unstructured.Unstructured {
	t.Helper()
	mtc := tenant.NewMaasTenantConfig()
	if err := c.Get(context.Background(), types.NamespacedName{Namespace: testTenantNamespace, Name: tenant.MaasTenantConfigInstanceName}, mtc); err != nil {
		t.Fatalf("get MaasTenantConfig: %v", err)
	}
	return mtc
}

func TestReconcileAppliesAuthProxyForDefaultTenant(t *testing.T) {
	r, rec := newReconciler(t,
		newMTC(tenant.DefaultAITenantName, testInfraNamespace),
		newAITenant(aitenantOpts{issuer: testIssuer}),
		newGateway(httpsListener(testHostname)),
		credentialsSecret(),
	)

	res := reconcileMTC(t, r)

	if res.RequeueAfter != r.ResyncInterval {
		t.Errorf("RequeueAfter = %v, want resync interval %v", res.RequeueAfter, r.ResyncInterval)
	}
	sort.Strings(rec.applied)
	want := []string{
		"Deployment/" + testInfraNamespace + "/" + AuthProxyName,
		"NetworkPolicy/" + testInfraNamespace + "/" + AuthProxyName,
		"Service/" + testInfraNamespace + "/" + AuthProxyName,
		"ServiceAccount/" + testInfraNamespace + "/" + AuthProxyName,
	}
	if len(rec.applied) != len(want) {
		t.Fatalf("applied = %v, want %v", rec.applied, want)
	}
	for i := range want {
		if rec.applied[i] != want[i] {
			t.Errorf("applied[%d] = %q, want %q", i, rec.applied[i], want[i])
		}
	}
	if !controllerutil.ContainsFinalizer(getMTC(t, r.Client), CleanupFinalizer) {
		t.Error("cleanup finalizer was not added to the MaasTenantConfig")
	}
	for _, kind := range rec.gets {
		if kind == "GatewayConfig" {
			t.Error("reconciler read a GatewayConfig; the auth proxy must not depend on it")
		}
	}
}

func TestReconcileWaitsForCredentialsSecret(t *testing.T) {
	r, rec := newReconciler(t,
		newMTC(tenant.DefaultAITenantName, testInfraNamespace),
		newAITenant(aitenantOpts{issuer: testIssuer}),
		newGateway(httpsListener(testHostname)),
	)

	res := reconcileMTC(t, r)

	if res.RequeueAfter != constants.NotReadyRequeueInterval {
		t.Errorf("RequeueAfter = %v, want %v", res.RequeueAfter, constants.NotReadyRequeueInterval)
	}
	if len(rec.applied) != 0 {
		t.Errorf("applied %v without a credentials Secret", rec.applied)
	}
	if controllerutil.ContainsFinalizer(getMTC(t, r.Client), CleanupFinalizer) {
		t.Error("finalizer added before anything was deployed")
	}
}

func TestReconcileRequeuesUntilPrerequisitesExist(t *testing.T) {
	cases := map[string][]client.Object{
		"AITenant not ready": {
			newMTC(tenant.DefaultAITenantName, testInfraNamespace),
			newAITenant(aitenantOpts{issuer: testIssuer, notReady: true}),
		},
		"infra namespace not published": {
			newMTC(tenant.DefaultAITenantName, ""),
			newAITenant(aitenantOpts{issuer: testIssuer}),
		},
		"Gateway without concrete HTTPS hostname": {
			newMTC(tenant.DefaultAITenantName, testInfraNamespace),
			newAITenant(aitenantOpts{issuer: testIssuer}),
			newGateway(httpsListener("*.apps.example.com")),
			credentialsSecret(),
		},
	}
	for name, objects := range cases {
		t.Run(name, func(t *testing.T) {
			r, rec := newReconciler(t, objects...)
			if res := reconcileMTC(t, r); res.RequeueAfter != constants.NotReadyRequeueInterval {
				t.Errorf("RequeueAfter = %v, want %v", res.RequeueAfter, constants.NotReadyRequeueInterval)
			}
			if len(rec.applied) != 0 {
				t.Errorf("applied %v before prerequisites exist", rec.applied)
			}
		})
	}
}

func TestReconcileRemovesAuthProxyWhenNotWanted(t *testing.T) {
	withFinalizer := func(mtc *unstructured.Unstructured) *unstructured.Unstructured {
		controllerutil.AddFinalizer(mtc, CleanupFinalizer)
		return mtc
	}
	cases := map[string]struct {
		mtc      *unstructured.Unstructured
		aitenant *unstructured.Unstructured
	}{
		"no OIDC issuer (OpenShift mode)": {
			mtc:      withFinalizer(newMTC(tenant.DefaultAITenantName, testInfraNamespace)),
			aitenant: newAITenant(aitenantOpts{}),
		},
		"consumer portal disabled": {
			mtc:      withFinalizer(newMTC(tenant.DefaultAITenantName, testInfraNamespace)),
			aitenant: newAITenant(aitenantOpts{issuer: testIssuer, portalDisabled: true}),
		},
		"non-default tenant": {
			mtc:      withFinalizer(newMTC("team-a", testInfraNamespace)),
			aitenant: newAITenant(aitenantOpts{issuer: testIssuer}),
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			r, rec := newReconciler(t, tc.mtc, tc.aitenant, newGateway(httpsListener(testHostname)),
				credentialsSecret(), managedProxyDeployment())

			reconcileMTC(t, r)

			if len(rec.applied) != 0 {
				t.Errorf("applied %v when the auth proxy is not wanted", rec.applied)
			}
			err := r.Client.Get(context.Background(), types.NamespacedName{Namespace: testInfraNamespace, Name: AuthProxyName}, &appsv1.Deployment{})
			if !apierrors.IsNotFound(err) {
				t.Errorf("auth proxy Deployment still exists (err=%v)", err)
			}
			if controllerutil.ContainsFinalizer(getMTC(t, r.Client), CleanupFinalizer) {
				t.Error("cleanup finalizer was not removed")
			}
		})
	}
}

func TestReconcileDeletionCleansUpAndReleasesFinalizer(t *testing.T) {
	mtc := newMTC(tenant.DefaultAITenantName, testInfraNamespace)
	controllerutil.AddFinalizer(mtc, CleanupFinalizer)
	now := metav1.Now()
	mtc.SetDeletionTimestamp(&now)
	r, _ := newReconciler(t, mtc, managedProxyDeployment())

	reconcileMTC(t, r)

	err := r.Client.Get(context.Background(), types.NamespacedName{Namespace: testInfraNamespace, Name: AuthProxyName}, &appsv1.Deployment{})
	if !apierrors.IsNotFound(err) {
		t.Errorf("auth proxy Deployment still exists after MaasTenantConfig deletion (err=%v)", err)
	}
	// Releasing the last finalizer lets the fake client complete the delete.
	err = r.Client.Get(context.Background(), types.NamespacedName{Namespace: testTenantNamespace, Name: tenant.MaasTenantConfigInstanceName}, tenant.NewMaasTenantConfig())
	if !apierrors.IsNotFound(err) {
		t.Errorf("MaasTenantConfig still exists after finalizer release (err=%v)", err)
	}
}

func TestCleanupLeavesUnmanagedObjects(t *testing.T) {
	foreign := managedProxyDeployment()
	foreign.Labels = map[string]string{tenant.LabelManagedBy: "someone-else"}
	r, _ := newReconciler(t, foreign)

	if err := r.cleanup(context.Background(), testInfraNamespace); err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if err := r.Client.Get(context.Background(), types.NamespacedName{Namespace: testInfraNamespace, Name: AuthProxyName}, &appsv1.Deployment{}); err != nil {
		t.Errorf("unmanaged Deployment was deleted: %v", err)
	}
}

func TestMaasTenantConfigForAITenantOnlyMapsDefaultTenant(t *testing.T) {
	r := &Reconciler{}
	if reqs := r.maasTenantConfigForAITenant(context.Background(), newAITenant(aitenantOpts{})); len(reqs) != 1 ||
		reqs[0].Namespace != testTenantNamespace || reqs[0].Name != tenant.MaasTenantConfigInstanceName {
		t.Errorf("default AITenant mapped to %v", reqs)
	}
	other := newAITenant(aitenantOpts{})
	other.SetName("team-a")
	if reqs := r.maasTenantConfigForAITenant(context.Background(), other); len(reqs) != 0 {
		t.Errorf("non-default AITenant mapped to %v", reqs)
	}
}

func TestProviderCAKeysSkipsEmptyBundleKeys(t *testing.T) {
	const cert = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
	bundle := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: TrustedCABundleConfigMap, Namespace: testInfraNamespace},
		Data:       map[string]string{"ca-bundle.crt": cert, "odh-ca-bundle.crt": "\n"},
	}
	r, _ := newReconciler(t, bundle)
	keys, err := r.providerCAKeys(context.Background(), testInfraNamespace)
	if err != nil {
		t.Fatalf("providerCAKeys: %v", err)
	}
	if len(keys) != 1 || keys[0] != "ca-bundle.crt" {
		t.Errorf("keys = %v, want [ca-bundle.crt]", keys)
	}

	r, _ = newReconciler(t)
	if keys, err := r.providerCAKeys(context.Background(), testInfraNamespace); err != nil || len(keys) != 0 {
		t.Errorf("missing bundle: keys = %v, err = %v", keys, err)
	}
}
