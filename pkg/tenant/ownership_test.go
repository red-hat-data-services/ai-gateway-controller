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
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
)

func TestShouldDeletePraxisResource(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		obj    map[string]any
		delete bool
	}{
		{
			name: "ai-gateway-controller owned via label",
			obj: map[string]any{
				"metadata": map[string]any{
					"labels": map[string]any{LabelManagedBy: ManagedByAIGatewayController},
				},
			},
			delete: true,
		},
		{
			name: "ai-gateway-controller owned",
			obj: map[string]any{
				"metadata": map[string]any{
					"managedFields": []any{map[string]any{"manager": render.FieldOwner}},
				},
			},
			delete: true,
		},
		{
			name: "maas-controller owned only",
			obj: map[string]any{
				"metadata": map[string]any{
					"managedFields": []any{map[string]any{"manager": maasControllerFieldOwner}},
				},
			},
			delete: false,
		},
		{
			name: "managed false",
			obj: map[string]any{
				"metadata": map[string]any{
					"annotations":   map[string]any{AnnotationManaged: "false"},
					"managedFields": []any{map[string]any{"manager": render.FieldOwner}},
				},
			},
			delete: false,
		},
		{
			name:   "no managedFields",
			obj:    map[string]any{"metadata": map[string]any{}},
			delete: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			u := &unstructured.Unstructured{Object: tt.obj}
			if got := shouldDeletePraxisResource(u); got != tt.delete {
				t.Fatalf("shouldDeletePraxisResource() = %v, want %v", got, tt.delete)
			}
		})
	}
}
