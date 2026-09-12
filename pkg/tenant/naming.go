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

// ID returns the resource-naming tenant identifier for an AITenant name.
// The default/legacy AITenant keeps the empty identifier so its resources
// stay unsuffixed (mirrors maas-controller's tenantreconcile.TenantIdentifierFor
// treatment of the default tenant); every other AITenant name is used as-is.
func ID(aitenantName string) string {
	if aitenantName == DefaultAITenantName {
		return ""
	}
	return aitenantName
}

// ResourceName returns base for the default tenant ("") and "base-tenantID"
// otherwise (mirrors tenantreconcile.resourceNameForTenant).
func ResourceName(base, tenantID string) string {
	if tenantID == "" {
		return base
	}
	return base + "-" + tenantID
}

func PayloadProcessingDeploymentName(tenantID string) string {
	return ResourceName(PayloadProcessingName, tenantID)
}

func PayloadPreProcessingDeploymentName(tenantID string) string {
	return ResourceName(PayloadPreProcessingName, tenantID)
}

func PayloadProcessingServiceName(tenantID string) string {
	return ResourceName(PayloadProcessingName, tenantID)
}

func PayloadPreProcessingServiceName(tenantID string) string {
	return ResourceName(PayloadPreProcessingName, tenantID)
}

func PayloadProcessingServiceAccountName(tenantID string) string {
	return ResourceName(PayloadProcessingName, tenantID)
}

func PayloadProcessingNetworkPolicyName(tenantID string) string {
	return ResourceName(PayloadProcessingName, tenantID)
}

func PayloadProcessingEnvoyFilterName(tenantID string) string {
	return ResourceName(PayloadProcessingName, tenantID)
}

func PayloadProcessingPluginsConfigMapForTenant(tenantID string) string {
	return ResourceName(PayloadProcessingPluginsConfigMapName, tenantID)
}

func PayloadProcessingReaderClusterRoleBindingNameForTenant(tenantID string) string {
	return ResourceName(PayloadProcessingReaderClusterRoleBindingName, tenantID)
}
