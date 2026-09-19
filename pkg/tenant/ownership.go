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
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
)

const (
	// AnnotationManaged mirrors maas-controller tenantreconcile.AnnotationManaged.
	AnnotationManaged = "opendatahub.io/managed"

	maasControllerFieldOwner = "maas-controller"
)

func isManagedFalse(obj *unstructured.Unstructured) bool {
	annotations := obj.GetAnnotations()
	return annotations != nil && annotations[AnnotationManaged] == "false"
}

func hasSSAFieldManager(obj *unstructured.Unstructured, manager string) bool {
	managedFields, found, err := unstructured.NestedSlice(obj.Object, "metadata", "managedFields")
	if err != nil || !found {
		return false
	}
	for _, entry := range managedFields {
		field, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		mgr, _, _ := unstructured.NestedString(field, "manager")
		if mgr == manager {
			return true
		}
	}
	return false
}

// shouldDeletePraxisResource reports whether cleanup may delete an existing
// object at a payload-processing name. Skips legacy IPP objects owned by
// maas-controller (symmetric with maas one-shot cleanup skipping
// ai-gateway-controller-owned resources).
//
// opendatahub.io/managed=false does NOT block cleanup: that annotation only
// opts a resource out of steady-state reconcile elsewhere. On backend
// switch-off this controller must remove its whole name set — including any
// unmanaged leftover (e.g. a plugins ConfigMap stamped managed=false by
// maas-controller) — so the peer controller can recreate the shared names in
// its own schema.
func shouldDeletePraxisResource(obj *unstructured.Unstructured) bool {
	labels := obj.GetLabels()
	if labels[LabelManagedBy] == maasControllerFieldOwner {
		return false
	}
	if hasSSAFieldManager(obj, maasControllerFieldOwner) && !hasSSAFieldManager(obj, render.FieldOwner) && labels[LabelManagedBy] != ManagedByAIGatewayController {
		return false
	}
	if isManagedFalse(obj) {
		return true
	}
	return labels[LabelManagedBy] == ManagedByAIGatewayController || hasSSAFieldManager(obj, render.FieldOwner)
}
