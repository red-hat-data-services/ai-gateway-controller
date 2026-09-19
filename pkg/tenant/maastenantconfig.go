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

import "k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

// NewMaasTenantConfig returns an empty unstructured object with the
// MaasTenantConfig GVK set, ready for Get or for use with the controller-
// runtime builder. This is this controller's primary watch target (mirrors
// maas-controller's TenantReconciler watching the same object).
func NewMaasTenantConfig() *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(MaasTenantConfigGVK)
	return u
}

// PayloadProcessingType reads the AnnotationPayloadProcessingType annotation
// from a MaasTenantConfig. Absent/empty means IPP; this package only cares
// whether it equals PayloadProcessingBackendPraxis.
func PayloadProcessingType(mtc *unstructured.Unstructured) string {
	return mtc.GetAnnotations()[AnnotationPayloadProcessingType]
}

// UsesPraxis reports whether a MaasTenantConfig opted into this controller.
func UsesPraxis(mtc *unstructured.Unstructured) bool {
	return PayloadProcessingType(mtc) == PayloadProcessingBackendPraxis
}

// IdentifierFor derives the per-tenant resource-naming identifier from
// a MaasTenantConfig's labels, mirroring maas-controller's
// tenantreconcile.TenantIdentifierFor: the default/legacy tenant (unlabeled,
// or labeled with DefaultAITenantName) returns "" so its resources keep the
// unsuffixed names Phase 1 always used; every other AITenant-managed tenant
// returns its tenant name for "{base}-{tenantID}" naming.
func IdentifierFor(mtc *unstructured.Unstructured) string {
	labels := mtc.GetLabels()
	if labels == nil || labels[LabelManagedByAITenant] != "true" {
		return ""
	}
	name := labels[LabelTenantName]
	if name == DefaultAITenantName {
		return ""
	}
	return name
}

// OwningAITenantRef reads the AnnotationAITenantName / AnnotationAITenantNamespace
// annotations maas-controller's AITenantReconciler stamps onto every
// AITenant-managed MaasTenantConfig. ok is false until both are populated.
// Callers must not treat these annotations as proof of ownership: tenant
// users can patch them, so resolveOwningAITenant also checks
// status.tenantNamespace against the MaasTenantConfig's namespace.
func OwningAITenantRef(mtc *unstructured.Unstructured) (name, namespace string, ok bool) {
	annotations := mtc.GetAnnotations()
	if annotations == nil {
		return "", "", false
	}
	name = annotations[AnnotationAITenantName]
	namespace = annotations[AnnotationAITenantNamespace]
	return name, namespace, name != "" && namespace != ""
}

// ConfigNamespace reads status.tenantNamespace from an AITenant —
// the namespace where maas-controller creates/adopts that tenant's
// MaasTenantConfig/default-tenant object (mirrors maas-controller's
// AITenantReconciler setting aitenant.Status.TenantNamespace). Used to map
// an AITenant watch event back to the MaasTenantConfig this controller
// primarily reconciles, without needing to duplicate maas-controller's
// TenantNamespaceForAITenant naming convention (which depends on a
// configurable default tenant namespace this controller does not know).
func ConfigNamespace(aitenant *unstructured.Unstructured) (namespace string, ok bool) {
	namespace, _, _ = unstructured.NestedString(aitenant.Object, "status", "tenantNamespace")
	return namespace, namespace != ""
}
