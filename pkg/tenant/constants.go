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

// Package tenant watches AITenant CRs (owned by maas-controller) and, for
// every tenant whose spec.payloadProcessing.type is "praxis", renders and
// SSA-applies a dedicated per-tenant copy of the vendored praxis-extproc
// manifests into that tenant's Gateway namespace.
//
// This package deliberately reads AITenant via unstructured +
// schema.GroupVersionKind rather than importing
// models-as-a-service/maas-controller's Go types: that module's go.mod pulls
// in kserve, knative, KEDA, openshift/api, and more, none of which this
// controller needs, and DESIGN.md's stated goal is to keep this repo's
// dependency graph minimal. AITenant's on-wire JSON shape is the only
// contract this package relies on.
package tenant

import "k8s.io/apimachinery/pkg/runtime/schema"

// AITenantGVK identifies the AITenant CRD (maas-controller
// api/maas/v1alpha1.AITenant), used to build unstructured objects for Get
// and to register the watch in SetupWithManager.
var AITenantGVK = schema.GroupVersionKind{
	Group:   "maas.opendatahub.io",
	Version: "v1alpha1",
	Kind:    "AITenant",
}

const (
	// AnnotationPayloadProcessingType is the AITenant annotation that
	// selects the tenant's payload-processing dataplane (mirrors
	// maas-controller's tenantreconcile.AnnotationPayloadProcessingType.
	// Absent, empty, or any value other than PayloadProcessingBackendPraxis
	// means IPP (maas-controller), out of scope for this controller.
	AnnotationPayloadProcessingType = "maas.opendatahub.io/payload-processing-type"

	// PayloadProcessingBackendPraxis is the only AnnotationPayloadProcessingType
	// value that opts a tenant into this controller (mirrors
	// maas-controller's tenantreconcile.PayloadProcessingTypePraxis).
	PayloadProcessingBackendPraxis = "praxis"

	// AITenantPhaseActive is the AITenant status.phase value maas-controller's
	// AITenant reconciler sets only after it has validated the tenant's
	// Gateway, and created its namespace, MaasTenantConfig, and RBAC. Used
	// as the readiness gate before installing praxis-extproc: status.gatewayRef
	// alone is not sufficient, since AITenantReconciler populates it
	// optimistically (from spec, unvalidated) before that work happens.
	AITenantPhaseActive = "Active"

	// PraxisCleanupFinalizer is added to every AITenant this controller has
	// applied praxis-extproc resources for, so it can clean them up when
	// the tenant switches away from praxis or the AITenant is deleted (SSA
	// alone never deletes resources that fall out of the render set).
	PraxisCleanupFinalizer = "ai-gateway-controller.opendatahub.io/praxis-cleanup"

	// DefaultAITenantName is the AITenant that represents the legacy/default
	// models-as-a-service installation (mirrors
	// maasv1alpha1.DefaultAITenantName / tenantreconcile.DefaultAITenantName).
	// Resources for this tenant keep the unsuffixed names Phase 1 always used,
	// for backward compatibility.
	DefaultAITenantName = "models-as-a-service"

	// Base resource names present in the vendored praxis-extproc overlay
	// (config/manifests/praxis-extproc/overlays/odh). Per-tenant resources
	// suffix these with "-{tenantID}"; the default tenant keeps them as-is.
	PayloadProcessingName                         = "payload-processing"
	PayloadPreProcessingName                      = "payload-pre-processing"
	PayloadProcessingPluginsConfigMapName         = "payload-processing-plugins"
	PayloadProcessingReaderClusterRoleBindingName = "payload-processing-reader"

	// LabelTenantInstance distinguishes pods/Services when multiple
	// per-tenant praxis-extproc stacks share a gateway namespace (mirrors
	// maas-controller's tenantreconcile.LabelTenantInstance).
	LabelTenantInstance = "maas.opendatahub.io/tenant-instance"

	// maxKubernetesNameLength is the Kubernetes object name limit (RFC 1123
	// label / DNS subdomain component). Rename returns an error rather than
	// applying a name that would exceed it.
	maxKubernetesNameLength = 63
)

// GVKs of the resources cleanup deletes by computed name. Kept alongside
// AITenantGVK rather than in render/postrender.go: these are the identity
// half of "what did we apply for this tenant", cleanup's own concern, not
// the kustomize-build/placeholder-substitution concern render.PostRender
// owns.
var (
	gvkDeployment         = schema.GroupVersionKind{Group: "apps", Version: "v1", Kind: "Deployment"}
	gvkService            = schema.GroupVersionKind{Version: "v1", Kind: "Service"}
	gvkConfigMap          = schema.GroupVersionKind{Version: "v1", Kind: "ConfigMap"}
	gvkServiceAccount     = schema.GroupVersionKind{Version: "v1", Kind: "ServiceAccount"}
	gvkNetworkPolicy      = schema.GroupVersionKind{Group: "networking.k8s.io", Version: "v1", Kind: "NetworkPolicy"}
	gvkEnvoyFilter        = schema.GroupVersionKind{Group: "networking.istio.io", Version: "v1alpha3", Kind: "EnvoyFilter"}
	gvkDestinationRule    = schema.GroupVersionKind{Group: "networking.istio.io", Version: "v1", Kind: "DestinationRule"}
	gvkClusterRoleBinding = schema.GroupVersionKind{Group: "rbac.authorization.k8s.io", Version: "v1", Kind: "ClusterRoleBinding"}
)
