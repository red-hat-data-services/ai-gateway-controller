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
	"slices"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/event"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
)

func aitenantForPredicate(t *testing.T, mutate func(*unstructured.Unstructured)) *unstructured.Unstructured {
	t.Helper()
	aitenant := NewAITenant()
	aitenant.SetNamespace("ai-tenants")
	aitenant.SetName("tenant-a")
	if mutate != nil {
		mutate(aitenant)
	}
	return aitenant
}

func mtcForPredicate(mutate func(*unstructured.Unstructured)) *unstructured.Unstructured {
	mtc := NewMaasTenantConfig()
	mtc.SetNamespace("e2e-tenant-a")
	mtc.SetName("maas-tenant-config")
	if mutate != nil {
		mutate(mtc)
	}
	return mtc
}

func updateFor(old, updated client.Object) event.UpdateEvent {
	return event.UpdateEvent{ObjectOld: old, ObjectNew: updated}
}

func TestAITenantPredicate(t *testing.T) {
	preds := tenantEventPredicates()["aitenant"]

	cases := []struct {
		name  string
		old   func(*unstructured.Unstructured)
		new   func(*unstructured.Unstructured)
		admit bool
	}{
		{
			name:  "spec change admits",
			old:   func(u *unstructured.Unstructured) { u.SetGeneration(1) },
			new:   func(u *unstructured.Unstructured) { u.SetGeneration(2) },
			admit: true,
		},
		{
			name: "tenantNamespace transition admits",
			old:  func(*unstructured.Unstructured) {},
			new: func(u *unstructured.Unstructured) {
				if err := unstructured.SetNestedField(u.Object, "e2e-tenant-a", "status", "tenantNamespace"); err != nil {
					t.Fatal(err)
				}
			},
			admit: true,
		},
		{
			name: "gatewayRef change admits",
			old: func(u *unstructured.Unstructured) {
				if err := unstructured.SetNestedField(u.Object, "gw-old", "status", "gatewayRef", "name"); err != nil {
					t.Fatal(err)
				}
			},
			new: func(u *unstructured.Unstructured) {
				if err := unstructured.SetNestedField(u.Object, "gw-new", "status", "gatewayRef", "name"); err != nil {
					t.Fatal(err)
				}
			},
			admit: true,
		},
		{
			name: "unrelated status write is dropped",
			old:  func(*unstructured.Unstructured) {},
			new: func(u *unstructured.Unstructured) {
				if err := unstructured.SetNestedField(u.Object, "something", "status", "unrelated"); err != nil {
					t.Fatal(err)
				}
			},
			admit: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := preds.Update(updateFor(aitenantForPredicate(t, tc.old), aitenantForPredicate(t, tc.new)))
			if got != tc.admit {
				t.Errorf("admitted = %v, want %v", got, tc.admit)
			}
		})
	}
}

func TestMaasTenantConfigPredicate(t *testing.T) {
	preds := tenantEventPredicates()["maastenantconfig"]

	cases := []struct {
		name  string
		old   func(*unstructured.Unstructured)
		new   func(*unstructured.Unstructured)
		admit bool
	}{
		{
			name:  "spec change admits",
			old:   func(u *unstructured.Unstructured) { u.SetGeneration(1) },
			new:   func(u *unstructured.Unstructured) { u.SetGeneration(2) },
			admit: true,
		},
		{
			name: "backend annotation flip admits",
			old: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationPayloadProcessingType: PayloadProcessingBackendIPP})
			},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationPayloadProcessingType: "praxis"})
			},
			admit: true,
		},
		{
			name: "response body mode annotation flip admits",
			old: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationExtProcResponseBodyMode: "STREAMED"})
			},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationExtProcResponseBodyMode: "BUFFERED"})
			},
			admit: true,
		},
		{
			name: "response body mode annotation clear admits",
			old: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationExtProcResponseBodyMode: "BUFFERED"})
			},
			new:   func(u *unstructured.Unstructured) { u.SetAnnotations(map[string]string{}) },
			admit: true,
		},
		{
			name: "max requests annotation set admits",
			old:  func(*unstructured.Unstructured) {},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationExtProcMaxRequests: "1024"})
			},
			admit: true,
		},
		{
			name: "max requests annotation change admits",
			old: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationExtProcMaxRequests: "64"})
			},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationExtProcMaxRequests: "1024"})
			},
			admit: true,
		},
		{
			name: "max requests annotation clear admits",
			old: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationExtProcMaxRequests: "1024"})
			},
			new:   func(u *unstructured.Unstructured) { u.SetAnnotations(map[string]string{}) },
			admit: true,
		},
		{
			name: "max body bytes annotation set admits",
			old:  func(*unstructured.Unstructured) {},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationExtProcMaxBodyBytes: "20971520"})
			},
			admit: true,
		},
		{
			name: "force migration annotation set admits",
			old:  func(*unstructured.Unstructured) {},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationForcePayloadProcessingMigration: "true"})
			},
			admit: true,
		},
		{
			// maas-controller ends the IPP handoff wait with this write.
			name: "cleanup-complete handoff signal admits",
			old:  func(*unstructured.Unstructured) {},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationPayloadProcessingStatus: PayloadProcessingStatusCleanupComplete})
			},
			admit: true,
		},
		{
			// A reconcile that re-reads its own earlier claim from a cache that
			// has just caught up waits for this event.
			name: "steady claim admits",
			old: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{
					AnnotationExtProcMaxRequests:      "1024",
					AnnotationPayloadProcessingStatus: PayloadProcessingStatusCleanupComplete,
				})
			},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{
					AnnotationExtProcMaxRequests:      "1024",
					AnnotationPayloadProcessingStatus: PayloadProcessingStatusSteady,
				})
			},
			admit: true,
		},
		{
			name: "steady claim alongside another annotation change admits",
			old: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{
					AnnotationExtProcMaxRequests:      "64",
					AnnotationPayloadProcessingStatus: PayloadProcessingStatusCleanupComplete,
				})
			},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{
					AnnotationExtProcMaxRequests:      "1024",
					AnnotationPayloadProcessingStatus: PayloadProcessingStatusSteady,
				})
			},
			admit: true,
		},
		{
			// IdentifierFor names every per-tenant resource, including the
			// plugins ConfigMap the migration gate waits on.
			name: "tenant identity label change admits",
			old: func(u *unstructured.Unstructured) {
				u.SetLabels(map[string]string{LabelManagedByAITenant: "true", LabelTenantName: "tenant-a"})
			},
			new: func(u *unstructured.Unstructured) {
				u.SetLabels(map[string]string{LabelManagedByAITenant: "true", LabelTenantName: "tenant-b"})
			},
			admit: true,
		},
		{
			name: "any other annotation change admits",
			old:  func(*unstructured.Unstructured) {},
			new: func(u *unstructured.Unstructured) {
				u.SetAnnotations(map[string]string{AnnotationAITenantName: "tenant-a"})
			},
			admit: true,
		},
		{
			name: "status-only update is dropped",
			old:  func(*unstructured.Unstructured) {},
			new: func(u *unstructured.Unstructured) {
				if err := unstructured.SetNestedField(u.Object, "Ready", "status", "phase"); err != nil {
					t.Fatal(err)
				}
			},
			admit: false,
		},
		{
			name:  "unrelated label change is dropped",
			old:   func(*unstructured.Unstructured) {},
			new:   func(u *unstructured.Unstructured) { u.SetLabels(map[string]string{"unrelated": "bump"}) },
			admit: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := preds.Update(updateFor(mtcForPredicate(tc.old), mtcForPredicate(tc.new)))
			if got != tc.admit {
				t.Errorf("admitted = %v, want %v", got, tc.admit)
			}
		})
	}
}

func TestNotControllerOwned(t *testing.T) {
	owned := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "agc-cred-x", Labels: map[string]string{managedByLabel: render.FieldOwner}}}
	foreign := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "source-api-key"}}

	if notControllerOwned(owned) {
		t.Error("controller-owned secret admitted; want excluded")
	}
	if !notControllerOwned(foreign) {
		t.Error("foreign secret excluded; want admitted")
	}
}

func TestTenantSecretPredicate(t *testing.T) {
	preds := tenantSecretPredicate()
	owned := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "agc-cred-x", Labels: map[string]string{managedByLabel: render.FieldOwner}}}
	foreign := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "source-api-key"}}

	if preds.Create(event.CreateEvent{Object: owned}) {
		t.Error("create of controller-owned secret admitted; want excluded")
	}
	if !preds.Create(event.CreateEvent{Object: foreign}) {
		t.Error("create of foreign secret excluded; want admitted")
	}
	if preds.Update(updateFor(owned, owned)) {
		t.Error("update of controller-owned secret admitted; want excluded")
	}
	if !preds.Update(updateFor(foreign, foreign)) {
		t.Error("update of foreign secret excluded; want admitted")
	}
	// Deletes are always admitted: a credential copy is removed by the
	// attachment reconciler acting on the model in the model's namespace, so
	// the Secret delete is the only tenant-side trigger to drop the candidate
	// from the rendered stack. A foreign source being deleted must equally
	// reconcile.
	for _, obj := range []client.Object{owned, foreign} {
		if !preds.Delete(event.DeleteEvent{Object: obj}) {
			t.Errorf("delete of %s excluded; want admitted", obj.GetName())
		}
	}
}

func TestPluginsConfigMapPredicate(t *testing.T) {
	preds := pluginsConfigMapPredicate()
	owned := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: PayloadProcessingPluginsConfigMapName, Labels: map[string]string{managedByLabel: render.FieldOwner}}}
	leftover := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: PayloadProcessingPluginsConfigMapName}}

	if preds.Create(event.CreateEvent{Object: owned}) || preds.Update(updateFor(owned, owned)) {
		t.Error("write to the controller-owned plugins ConfigMap admitted; want excluded")
	}
	if !preds.Create(event.CreateEvent{Object: leftover}) || !preds.Update(updateFor(leftover, leftover)) {
		t.Error("write to a leftover plugins ConfigMap excluded; want admitted")
	}
	// IPP data in a ConfigMap carrying this controller's label still blocks
	// the gate; changing it away must reach the queue.
	ippOwned := owned.DeepCopy()
	ippOwned.Data = map[string]string{ippProcessingConfigKey: "kind: PayloadProcessorConfig\n"}
	if !preds.Update(updateFor(ippOwned, owned)) {
		t.Error("update away from IPP data on a controller-owned plugins ConfigMap excluded; want admitted")
	}
	// Removing a leftover ends the migration gate's wait; removing ours must
	// be re-applied.
	for _, obj := range []client.Object{owned, leftover} {
		if !preds.Delete(event.DeleteEvent{Object: obj}) {
			t.Error("delete of a plugins ConfigMap excluded; want admitted")
		}
	}
}

func TestMaasTenantConfigForPluginsConfigMap(t *testing.T) {
	// The default tenant's owning AITenant is not published, so its gateway
	// namespace is unknown and any namespace maps to it.
	defaultTenant := newMTC(DefaultAITenantName, "", PayloadProcessingBackendPraxis, DefaultAITenantName, "ai-tenants")
	named := newMTC("tenant-ns", "redteam", PayloadProcessingBackendPraxis, "redteam", "ai-tenants")
	namedOwner := newAITenantOwner("redteam", "ai-tenants", AITenantPhaseActive, "my-gateway", "openshift-ingress", "tenant-ns")
	deleting := withMTCFinalizer(newMTC("deleting-ns", "deleting", PayloadProcessingBackendPraxis, "deleting", "ai-tenants"))
	deleting.SetDeletionTimestamp(new(metav1.Now()))
	legacy := newMTC("legacy-ns", "legacy", PayloadProcessingBackendIPP, "legacy", "ai-tenants")
	c := fake.NewClientBuilder().WithScheme(mtcSchemeForTests()).
		WithObjects(defaultTenant, named, namedOwner, deleting, legacy).
		WithIndex(NewMaasTenantConfig(), pluginsConfigMapIndex, indexMaasTenantConfigByPluginsConfigMap).
		Build()
	r := &Reconciler{Client: c}

	cases := []struct {
		desc, name, namespace string
		want                  []client.ObjectKey
	}{
		{desc: "default tenant", name: PayloadProcessingPluginsConfigMapForTenant(""), namespace: "openshift-ingress", want: []client.ObjectKey{client.ObjectKeyFromObject(defaultTenant)}},
		{desc: "named tenant in its gateway namespace", name: PayloadProcessingPluginsConfigMapForTenant("redteam"), namespace: "openshift-ingress", want: []client.ObjectKey{client.ObjectKeyFromObject(named)}},
		{desc: "same name outside the gateway namespace", name: PayloadProcessingPluginsConfigMapForTenant("redteam"), namespace: "elsewhere"},
		// A tenant being torn down deletes its own plugins ConfigMap, and a
		// tenant on legacy IPP has no migration gate to wake.
		{desc: "deleting tenant", name: PayloadProcessingPluginsConfigMapForTenant("deleting"), namespace: "openshift-ingress"},
		{desc: "legacy IPP tenant", name: PayloadProcessingPluginsConfigMapForTenant("legacy"), namespace: "openshift-ingress"},
		{desc: "no such tenant", name: PayloadProcessingPluginsConfigMapForTenant("unknown"), namespace: "openshift-ingress"},
		{desc: "routing overlay", name: praxisOverlayName, namespace: "openshift-ingress"},
		{desc: "external model plugins", name: PayloadProcessingExternalModelPluginsConfigMapForTenant("redteam"), namespace: "openshift-ingress"},
	}
	for _, tc := range cases {
		t.Run(tc.desc, func(t *testing.T) {
			cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: tc.name, Namespace: tc.namespace}}
			var got []client.ObjectKey
			for _, req := range r.maasTenantConfigForPluginsConfigMap(t.Context(), cm) {
				got = append(got, req.NamespacedName)
			}
			if !slices.Equal(got, tc.want) {
				t.Errorf("requests = %v, want %v", got, tc.want)
			}
		})
	}
}
