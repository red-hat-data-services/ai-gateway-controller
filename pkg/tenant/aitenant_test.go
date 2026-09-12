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
)

// aitenantFixture builds an unstructured AITenant with
// AnnotationPayloadProcessingType (empty payloadProcessingType omits the
// annotation entirely, matching a real AITenant that never set it),
// status.phase, and status.gatewayRef.
func aitenantFixture(payloadProcessingType, phase, gatewayName, gatewayNamespace string) *unstructured.Unstructured {
	u := NewAITenant()
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

func TestNewAITenantSetsGVK(t *testing.T) {
	u := NewAITenant()
	if got := u.GroupVersionKind(); got != AITenantGVK {
		t.Fatalf("GVK = %v, want %v", got, AITenantGVK)
	}
}

func TestPayloadProcessingTypeAbsentIsEmpty(t *testing.T) {
	u := aitenantFixture("", "", "", "")
	if got := PayloadProcessingType(u); got != "" {
		t.Fatalf("PayloadProcessingType = %q, want empty", got)
	}
}

func TestPayloadProcessingTypeReadsAnnotation(t *testing.T) {
	u := aitenantFixture("praxis", "", "", "")
	if got := PayloadProcessingType(u); got != "praxis" {
		t.Fatalf("PayloadProcessingType = %q, want %q", got, "praxis")
	}
	if got, want := u.GetAnnotations()[AnnotationPayloadProcessingType], "praxis"; got != want {
		t.Fatalf("fixture did not set the %s annotation: got %q, want %q", AnnotationPayloadProcessingType, got, want)
	}
}

func TestUsesPraxis(t *testing.T) {
	cases := []struct {
		name string
		typ  string
		want bool
	}{
		{"absent means IPP", "", false},
		{"praxis", "praxis", true},
		{"unexpected value", "ipp", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := UsesPraxis(aitenantFixture(c.typ, "", "", "")); got != c.want {
				t.Errorf("UsesPraxis(type=%q) = %v, want %v", c.typ, got, c.want)
			}
		})
	}
}

func TestIsActive(t *testing.T) {
	cases := []struct {
		name  string
		phase string
		want  bool
	}{
		{"absent phase", "", false},
		{"Pending", "Pending", false},
		{"Active", "Active", true},
		{"Failed", "Failed", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := IsActive(aitenantFixture("praxis", c.phase, "", "")); got != c.want {
				t.Errorf("IsActive(phase=%q) = %v, want %v", c.phase, got, c.want)
			}
		})
	}
}

func TestGatewayRefNotReadyWhenUnset(t *testing.T) {
	u := aitenantFixture("praxis", "Active", "", "")
	if _, _, ok := GatewayRef(u); ok {
		t.Fatal("GatewayRef ok = true, want false when status.gatewayRef is unset")
	}
}

func TestGatewayRefNotReadyWhenPartiallySet(t *testing.T) {
	u := aitenantFixture("praxis", "Active", "my-gateway", "")
	if _, _, ok := GatewayRef(u); ok {
		t.Fatal("GatewayRef ok = true, want false when namespace is missing")
	}
}

func TestGatewayRefReady(t *testing.T) {
	u := aitenantFixture("praxis", "Active", "my-gateway", "my-namespace")
	name, namespace, ok := GatewayRef(u)
	if !ok {
		t.Fatal("GatewayRef ok = false, want true")
	}
	if name != "my-gateway" || namespace != "my-namespace" {
		t.Fatalf("GatewayRef = (%q, %q), want (%q, %q)", name, namespace, "my-gateway", "my-namespace")
	}
}
