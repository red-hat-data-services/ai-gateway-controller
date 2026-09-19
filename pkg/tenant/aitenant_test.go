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

// aitenantFixture builds an unstructured AITenant with status.phase and
// status.gatewayRef. AnnotationPayloadProcessingType is no longer read from
// AITenant (see maastenantconfig_test.go for that), so this fixture no
// longer sets it.
func aitenantFixture(phase, gatewayName, gatewayNamespace string) *unstructured.Unstructured {
	u := NewAITenant()
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
			if got := IsActive(aitenantFixture(c.phase, "", "")); got != c.want {
				t.Errorf("IsActive(phase=%q) = %v, want %v", c.phase, got, c.want)
			}
		})
	}
}

func TestGatewayRefNotReadyWhenUnset(t *testing.T) {
	u := aitenantFixture("Active", "", "")
	if _, _, ok := GatewayRef(u); ok {
		t.Fatal("GatewayRef ok = true, want false when status.gatewayRef is unset")
	}
}

func TestGatewayRefNotReadyWhenPartiallySet(t *testing.T) {
	u := aitenantFixture("Active", "my-gateway", "")
	if _, _, ok := GatewayRef(u); ok {
		t.Fatal("GatewayRef ok = true, want false when namespace is missing")
	}
}

func TestGatewayRefReady(t *testing.T) {
	u := aitenantFixture("Active", "my-gateway", "my-namespace")
	name, namespace, ok := GatewayRef(u)
	if !ok {
		t.Fatal("GatewayRef ok = false, want true")
	}
	if name != "my-gateway" || namespace != "my-namespace" {
		t.Fatalf("GatewayRef = (%q, %q), want (%q, %q)", name, namespace, "my-gateway", "my-namespace")
	}
}

func TestConfigNamespace(t *testing.T) {
	t.Run("absent", func(t *testing.T) {
		u := NewAITenant()
		u.Object["status"] = map[string]any{}
		if _, ok := ConfigNamespace(u); ok {
			t.Fatal("ok = true, want false when status.tenantNamespace is unset")
		}
	})

	t.Run("present", func(t *testing.T) {
		u := NewAITenant()
		u.Object["status"] = map[string]any{"tenantNamespace": "ai-tenant-redteam"}
		ns, ok := ConfigNamespace(u)
		if !ok {
			t.Fatal("ok = false, want true")
		}
		if ns != "ai-tenant-redteam" {
			t.Fatalf("namespace = %q, want %q", ns, "ai-tenant-redteam")
		}
	})
}
