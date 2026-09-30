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
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestSchemeRegistration(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, AddToScheme(scheme))

	obj, err := scheme.New(schema.GroupVersionKind{Group: "aigateway.opendatahub.io", Version: "v1alpha1", Kind: "AIGuardrail"})
	require.NoError(t, err)
	assert.IsType(t, &AIGuardrail{}, obj)
}

func TestAIGuardrailDeepCopy(t *testing.T) {
	original := &AIGuardrail{
		Spec: AIGuardrailSpec{
			Provider: AIGuardrailProvider{
				Nemo: AIGuardrailNemoProvider{
					Ref: AIGuardrailNamespacedReference{Name: "tenant-nemo", Namespace: "guardrails"},
				},
			},
			Checks: []AIGuardrailCheck{{
				Name: "sensitive-data", ConfigID: "pii", Phases: []GuardrailPhase{GuardrailPhaseInput, GuardrailPhaseOutput},
			}},
		},
	}

	copied := original.DeepCopy()
	assert.Equal(t, original.Spec, copied.Spec)
	copied.Spec.Checks[0].Phases[0] = GuardrailPhaseOutput
	assert.Equal(t, GuardrailPhaseInput, original.Spec.Checks[0].Phases[0])
}
