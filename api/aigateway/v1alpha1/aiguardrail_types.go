/*
Copyright 2026 The opendatahub.io Authors.

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

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// GuardrailPhase identifies when a guardrail check is applied.
//
// +kubebuilder:validation:Enum=Input;Output
type GuardrailPhase string

const (
	GuardrailPhaseInput  GuardrailPhase = "Input"
	GuardrailPhaseOutput GuardrailPhase = "Output"
)

// AIGuardrail is a reusable, ordered collection of checks backed by a
// TrustyAI NemoGuardrails service.
//
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Ready",type="string",JSONPath=".status.conditions[?(@.type==\"Ready\")].status"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"
type AIGuardrail struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   AIGuardrailSpec   `json:"spec"`
	Status AIGuardrailStatus `json:"status,omitempty"`
}

// AIGuardrailSpec defines a guardrail provider and its ordered checks.
type AIGuardrailSpec struct {
	// Provider identifies the service used to execute the checks.
	// +kubebuilder:validation:Required
	Provider AIGuardrailProvider `json:"provider"`

	// Checks is the ordered list of independent checks. All selected checks
	// must pass. Check names are unique within this list.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=64
	// +kubebuilder:validation:XValidation:rule="self.all(x, self.exists_one(y, y.name == x.name))",message="check names must be unique"
	// +listType=atomic
	Checks []AIGuardrailCheck `json:"checks"`
}

// AIGuardrailProvider configures the TrustyAI provider used by a guardrail.
type AIGuardrailProvider struct {
	// Nemo references a NemoGuardrails resource. If Namespace is omitted,
	// the reference resolves in the AIGuardrail namespace.
	// +kubebuilder:validation:Required
	Nemo AIGuardrailNemoProvider `json:"nemo"`

	// Timeout is the maximum duration for an individual provider call.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:XValidation:rule="isDuration(self) && duration(self) > duration('0s')",message="timeout must be a valid positive duration"
	Timeout metav1.Duration `json:"timeout"`
}

// AIGuardrailNemoProvider is the typed NeMo provider binding.
type AIGuardrailNemoProvider struct {
	// Ref references a NemoGuardrails resource.
	// +kubebuilder:validation:Required
	Ref AIGuardrailNamespacedReference `json:"ref"`
}

// AIGuardrailNamespacedReference references a namespaced provider resource.
// Namespace is optional and defaults to the AIGuardrail namespace.
type AIGuardrailNamespacedReference struct {
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`
	Name string `json:"name"`

	// +optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	Namespace string `json:"namespace,omitempty"`
}

// AIGuardrailCheck defines one named NeMo configuration and the phases in
// which it is evaluated.
type AIGuardrailCheck struct {
	// Name is the stable name used by attachment resources to select this
	// check.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	Name string `json:"name"`

	// ConfigID identifies the configuration loaded by NemoGuardrails.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	ConfigID string `json:"configId"`

	// Phases is the non-empty set of request phases for this check.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=2
	// +listType=set
	Phases []GuardrailPhase `json:"phases"`
}

// AIGuardrailStatus defines the observed provider binding and readiness.
type AIGuardrailStatus struct {
	// ObservedGeneration is the latest spec generation processed by the
	// controller.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// BindingRevision changes when provider, Secret, configuration or
	// permission dependencies change independently of the policy generation.
	// +optional
	BindingRevision string `json:"bindingRevision,omitempty"`

	// Conditions report sanitized acceptance, reference, provider and
	// compatibility state. Credentials and provider configuration are never
	// exposed here.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true

// AIGuardrailList contains a list of AIGuardrail resources.
type AIGuardrailList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []AIGuardrail `json:"items"`
}

func init() {
	SchemeBuilder.Register(&AIGuardrail{}, &AIGuardrailList{})
}
