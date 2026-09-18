package tenant

import (
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	v1alpha1 "github.com/opendatahub-io/ai-gateway-controller/api/inference/v1alpha1"
)

func TestStandalonePraxisResourcesProjectAndDeduplicateCredentials(t *testing.T) {
	providers := []v1alpha1.ExternalProvider{
		{ObjectMeta: metav1.ObjectMeta{Name: "provider-a", Namespace: "tenant-a"}, Spec: v1alpha1.ExternalProviderSpec{Endpoint: "a.example.com", Auth: v1alpha1.AuthConfig{SecretRef: v1alpha1.NameReference{Name: "shared"}}}},
		{ObjectMeta: metav1.ObjectMeta{Name: "provider-b", Namespace: "tenant-a"}, Spec: v1alpha1.ExternalProviderSpec{Endpoint: "b.example.com", Auth: v1alpha1.AuthConfig{SecretRef: v1alpha1.NameReference{Name: "shared"}}}},
	}
	resources, err := StandalonePraxisResources("tenant-a", "tenant-a", "praxis:test", "Never", providers)
	if err != nil {
		t.Fatal(err)
	}
	if len(resources) != 4 {
		t.Fatalf("resource count = %d, want 4", len(resources))
	}
	deployment := findResource(resources, "Deployment", "praxis-tenant-a")
	volumes, found, err := unstructured.NestedSlice(deployment.Object, "spec", "template", "spec", "volumes")
	if err != nil || !found {
		t.Fatalf("Praxis volumes missing: found=%v err=%v", found, err)
	}
	if len(volumes) != 3 {
		t.Fatalf("volume count = %d, want config/routing/credentials", len(volumes))
	}
	routingVolume, ok := volumes[1].(map[string]any)
	if !ok {
		t.Fatal("routing volume has unexpected type")
	}
	routingConfigMap, ok := routingVolume["configMap"].(map[string]any)
	if !ok || routingConfigMap["optional"] != true {
		t.Fatalf("routing ConfigMap must be optional during bootstrap: %#v", routingVolume["configMap"])
	}
	podSecurity, found, err := unstructured.NestedMap(deployment.Object, "spec", "template", "spec", "securityContext")
	if err != nil || !found {
		t.Fatalf("pod security context missing: found=%v err=%v", found, err)
	}
	for _, field := range []string{"runAsUser", "runAsGroup", "fsGroup"} {
		if _, exists := podSecurity[field]; exists {
			t.Errorf("pod security context must not pin %s for OpenShift SCC portability", field)
		}
	}
	container, found, err := unstructured.NestedSlice(deployment.Object, "spec", "template", "spec", "containers")
	if err != nil || !found || len(container) != 1 {
		t.Fatalf("Praxis container missing: found=%v err=%v", found, err)
	}
	containerMap, ok := container[0].(map[string]any)
	if !ok {
		t.Fatalf("Praxis container has unexpected type %T", container[0])
	}
	if containerMap["imagePullPolicy"] != "Never" {
		t.Fatalf("image pull policy = %v, want Never", containerMap["imagePullPolicy"])
	}
	automount, found, err := unstructured.NestedBool(deployment.Object, "spec", "template", "spec", "automountServiceAccountToken")
	if err != nil || !found || automount {
		t.Fatalf("service-account token automount = %v, found=%v err=%v", automount, found, err)
	}
	projected, ok := volumes[2].(map[string]any)["projected"].(map[string]any)
	if !ok {
		t.Fatal("projected credentials volume missing or has unexpected type")
	}
	sources, found, err := unstructured.NestedSlice(projected, "sources")
	if err != nil || !found {
		t.Fatalf("projected Secret sources missing: found=%v err=%v", found, err)
	}
	if len(sources) != 1 {
		t.Fatalf("projected Secret source count = %d, want one deduplicated source", len(sources))
	}
	configMap := findResource(resources, "ConfigMap", "praxis-config-tenant-a")
	data, found, err := unstructured.NestedStringMap(configMap.Object, "data")
	if err != nil || !found {
		t.Fatalf("Praxis config data missing: found=%v err=%v", found, err)
	}
	config := data["config.yaml"]
	if strings.Contains(config, "secret-value") || !strings.Contains(config, "/etc/praxis/credentials/shared-") {
		t.Fatalf("config contains unexpected credential material or path: %s", config)
	}
	if !strings.Contains(config, "endpoints: [\"a.example.com:443\"]") ||
		!strings.Contains(config, "endpoints: [\"b.example.com:443\"]") {
		t.Fatalf("Praxis config did not preserve declared provider endpoints: %s", config)
	}
}

func TestStandalonePraxisResourcesRejectCrossNamespaceProvider(t *testing.T) {
	providers := []v1alpha1.ExternalProvider{{ObjectMeta: metav1.ObjectMeta{Name: "provider", Namespace: "other"}}}
	if _, err := StandalonePraxisResources("tenant-a", "tenant-a", "praxis:test", "Never", providers); err == nil {
		t.Fatal("expected cross-namespace provider rejection")
	}
}

func TestStandalonePraxisResourcesUsesExternalProviderEndpoint(t *testing.T) {
	providers := []v1alpha1.ExternalProvider{{
		ObjectMeta: metav1.ObjectMeta{Name: "provider-b", Namespace: "tenant-a"},
		Spec:       v1alpha1.ExternalProviderSpec{Endpoint: "provider-b.backend.svc.cluster.local", Auth: v1alpha1.AuthConfig{SecretRef: v1alpha1.NameReference{Name: "credentials"}}},
	}}
	resources, err := StandalonePraxisResources("tenant-a", "tenant-a", "praxis:test", "Never", providers)
	if err != nil {
		t.Fatal(err)
	}
	config := findResource(resources, "ConfigMap", "praxis-config-tenant-a")
	data, _, err := unstructured.NestedStringMap(config.Object, "data")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(data["config.yaml"], `provider-b.backend.svc.cluster.local:443`) {
		t.Fatalf("config did not use declared external endpoint: %s", data["config.yaml"])
	}
	if strings.Contains(data["config.yaml"], "provider-b.tenant-a.svc.cluster.local") {
		t.Fatalf("config synthesized a tenant-local endpoint: %s", data["config.yaml"])
	}
}

func TestStandalonePraxisResourcesConfiguresTLSAndAuthorityForExternalEndpoint(t *testing.T) {
	providers := []v1alpha1.ExternalProvider{{
		ObjectMeta: metav1.ObjectMeta{Name: "openai", Namespace: "tenant-a"},
		Spec:       v1alpha1.ExternalProviderSpec{Provider: "openai", Endpoint: "api.openai.com", Auth: v1alpha1.AuthConfig{SecretRef: v1alpha1.NameReference{Name: "credentials"}}},
	}}
	resources, err := StandalonePraxisResources("tenant-a", "tenant-a", "praxis:test", "Never", providers)
	if err != nil {
		t.Fatal(err)
	}
	config := findResource(resources, "ConfigMap", "praxis-config-tenant-a")
	data, _, err := unstructured.NestedStringMap(config.Object, "data")
	if err != nil {
		t.Fatal(err)
	}
	want := "            http:\n              authority: \"api.openai.com\"\n            tls:\n              sni: \"api.openai.com\"\n            endpoints: [\"api.openai.com:443\"]"
	if !strings.Contains(data["config.yaml"], want) {
		t.Fatalf("external provider config missing verified TLS and authority:\n%s", data["config.yaml"])
	}
}

func TestStandalonePraxisResourcesSeparatesExplicitPortFromSNI(t *testing.T) {
	providers := []v1alpha1.ExternalProvider{{
		ObjectMeta: metav1.ObjectMeta{Name: "provider", Namespace: "tenant-a"},
		Spec:       v1alpha1.ExternalProviderSpec{Endpoint: "provider.example.com:8443"},
	}}
	resources, err := StandalonePraxisResources("tenant-a", "tenant-a", "praxis:test", "Never", providers)
	if err != nil {
		t.Fatal(err)
	}
	config := findResource(resources, "ConfigMap", "praxis-config-tenant-a")
	data, _, err := unstructured.NestedStringMap(config.Object, "data")
	if err != nil {
		t.Fatal(err)
	}
	want := "            http:\n              authority: \"provider.example.com:8443\"\n            tls:\n              sni: \"provider.example.com\"\n            endpoints: [\"provider.example.com:8443\"]"
	if !strings.Contains(data["config.yaml"], want) {
		t.Fatalf("explicit provider port leaked into TLS SNI:\n%s", data["config.yaml"])
	}
}

func TestStandalonePraxisResourcesUsesExplicitPlaintextFixtureException(t *testing.T) {
	providers := []v1alpha1.ExternalProvider{{
		ObjectMeta: metav1.ObjectMeta{Name: "provider-a", Namespace: "tenant-a"},
		Spec:       v1alpha1.ExternalProviderSpec{Endpoint: "provider-a.maas-system.svc.cluster.local"},
	}}
	resources, err := StandalonePraxisResourcesWithOptions("tenant-a", "tenant-a", "praxis:test", "Never", providers, PraxisTransportOptions{PlaintextClusters: map[string]struct{}{"provider-provider-a": {}}})
	if err != nil {
		t.Fatal(err)
	}
	config := findResource(resources, "ConfigMap", "praxis-config-tenant-a")
	data, _, err := unstructured.NestedStringMap(config.Object, "data")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(data["config.yaml"], "tls:") || strings.Contains(data["config.yaml"], "authority:") {
		t.Fatalf("in-cluster fixture unexpectedly configured TLS or authority:\n%s", data["config.yaml"])
	}
}

func TestStandalonePraxisResourcesUsesTLSByDefaultForServiceDNS(t *testing.T) {
	providers := []v1alpha1.ExternalProvider{{
		ObjectMeta: metav1.ObjectMeta{Name: "provider-a", Namespace: "tenant-a"},
		Spec:       v1alpha1.ExternalProviderSpec{Endpoint: "provider-a.maas-system.svc.cluster.local"},
	}}
	resources, err := StandalonePraxisResources("tenant-a", "tenant-a", "praxis:test", "Never", providers)
	if err != nil {
		t.Fatal(err)
	}
	config := findResource(resources, "ConfigMap", "praxis-config-tenant-a")
	data, _, err := unstructured.NestedStringMap(config.Object, "data")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(data["config.yaml"], "sni: \"provider-a.maas-system.svc.cluster.local\"") {
		t.Fatalf("service DNS endpoint did not default to verified TLS:\n%s", data["config.yaml"])
	}
}

func TestStandalonePraxisResourcesRejectsMalformedEndpoint(t *testing.T) {
	providers := []v1alpha1.ExternalProvider{{ObjectMeta: metav1.ObjectMeta{Name: "provider", Namespace: "tenant-a"}, Spec: v1alpha1.ExternalProviderSpec{Endpoint: "https://provider.example"}}}
	if _, err := StandalonePraxisResources("tenant-a", "tenant-a", "praxis:test", "Never", providers); err == nil {
		t.Fatal("expected malformed endpoint rejection")
	}
}

func findResource(resources []unstructured.Unstructured, kind, name string) *unstructured.Unstructured {
	for i := range resources {
		if resources[i].GetKind() == kind && resources[i].GetName() == name {
			return &resources[i]
		}
	}
	panic("resource not found")
}
