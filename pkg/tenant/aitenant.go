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

// NewAITenant returns an empty unstructured object with the AITenant GVK
// set, ready for Get/List or for use with the controller-runtime builder.
func NewAITenant() *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(AITenantGVK)
	return u
}

// PayloadProcessingType reads the AnnotationPayloadProcessingType
// annotation. Absent/empty means IPP; this package only cares whether it
// equals PayloadProcessingBackendPraxis.
func PayloadProcessingType(aitenant *unstructured.Unstructured) string {
	return aitenant.GetAnnotations()[AnnotationPayloadProcessingType]
}

// UsesPraxis reports whether the AITenant opted into this controller.
func UsesPraxis(aitenant *unstructured.Unstructured) bool {
	return PayloadProcessingType(aitenant) == PayloadProcessingBackendPraxis
}

// IsActive reports whether maas-controller's AITenant reconciler has
// finished validating and bootstrapping this tenant (status.phase ==
// "Active": its Gateway is validated, and its namespace, MaasTenantConfig,
// and RBAC exist). Used as the readiness gate instead of GatewayRef alone,
// since status.gatewayRef is populated optimistically from spec before any
// of that validation happens.
func IsActive(aitenant *unstructured.Unstructured) bool {
	phase, _, _ := unstructured.NestedString(aitenant.Object, "status", "phase")
	return phase == AITenantPhaseActive
}

// GatewayRef reads status.gatewayRef.{name,namespace}. ok is false until
// the AITenant reconciler (maas-controller) has resolved and published the
// Gateway reference; callers should requeue rather than treat that as an
// error.
func GatewayRef(aitenant *unstructured.Unstructured) (name, namespace string, ok bool) {
	name, _, _ = unstructured.NestedString(aitenant.Object, "status", "gatewayRef", "name")
	namespace, _, _ = unstructured.NestedString(aitenant.Object, "status", "gatewayRef", "namespace")
	return name, namespace, name != "" && namespace != ""
}
