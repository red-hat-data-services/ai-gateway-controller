//go:build envtest

package envtest_test

import (
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/tenant"
)

func TestControlPlane(t *testing.T) {
	c := startControlPlane(t)

	t.Run("guardrail timeouts remain readable by typed clients", func(t *testing.T) {
		testGuardrailTimeoutAdmission(t, c)
	})

	t.Run("shipped permissions cover credential copies and reference grants", func(t *testing.T) {
		testShippedPermissions(t, c)
	})

	testGuardrailBinding(t, c)

	t.Run("adding and deleting an external model manages its routing", func(t *testing.T) {
		// Given an existing Praxis tenant with a configured provider.
		const namespace = "model-publication"
		maas := maasFixture{client: c}
		maas.existingPraxisTenant(t, namespace)
		awaitPraxisInstalled(t, c, namespace)
		provider := createProvider(t, c, namespace)

		// When a user adds a model using that provider.
		model := externalModel("model", namespace,
			withModelName("chat"),
			withProviderModel(provider.Name, "provider-model"),
		)
		require.NoError(t, c.Create(t.Context(), model))

		// Then the requested model/provider mapping and its workload are configured.
		routeName := awaitModelPublished(t, c, model, provider)

		// When the user deletes that model.
		require.NoError(t, c.Delete(t.Context(), model))

		// Then its routing and workload are removed and the finalizer releases it.
		awaitModelRemoved(t, c, model, routeName)
	})

	t.Run("an attached guardrail is enforced on ExternalModel routes until it is detached", func(t *testing.T) {
		const namespace = "guardrail-enforcement"
		maas := maasFixture{client: c}
		maas.existingPraxisTenant(t, namespace)
		awaitPraxisInstalled(t, c, namespace)
		provider := createProvider(t, c, namespace)
		model := externalModel("model", namespace,
			withModelName("chat"),
			withProviderModel(provider.Name, "provider-model"),
		)
		require.NoError(t, c.Create(t.Context(), model))
		awaitModelPublished(t, c, model, provider)
		attachment := awaitGuardrailEnforced(t, c, namespace)
		awaitGuardrailDetached(t, c, namespace, attachment)
	})

	t.Run("an ExtProc concurrency override reaches the gateway before the resync", func(t *testing.T) {
		// Given an existing Praxis tenant on the default ExtProc concurrency budget.
		const namespace = "extproc-concurrency"
		maas := maasFixture{client: c}
		maas.existingPraxisTenant(t, namespace)
		awaitPraxisInstalled(t, c, namespace)
		awaitExtProcMaxRequests(t, c, namespace, tenant.DefaultExtProcMaxRequests, eventuallyTimeout)

		// When an operator raises it with the experimental annotation.
		annotateTenantConfig(t, c, namespace, tenant.AnnotationExtProcMaxRequests, "64")

		// Then the gateway uses it within eventTimeout, before any requeue the
		// first passes may have left pending and well before the suite's
		// one-minute resync. Annotations do not bump the generation, so only
		// the watch predicate can bring it in that fast.
		awaitExtProcMaxRequests(t, c, namespace, 64, eventTimeout)

		// When the operator removes the annotation.
		annotateTenantConfig(t, c, namespace, tenant.AnnotationExtProcMaxRequests, "")

		// Then the default budget is restored just as quickly.
		awaitExtProcMaxRequests(t, c, namespace, tenant.DefaultExtProcMaxRequests, eventTimeout)
	})

	t.Run("a tenant waiting for the IPP handoff installs Praxis when maas signals cleanup-complete", func(t *testing.T) {
		// Given a Praxis tenant whose legacy IPP cleanup has not been signalled.
		const namespace = "handoff-signal"
		maas := maasFixture{client: c}
		maas.praxisTenant(t, namespace, "")
		awaitTenantConfigState(t, c, namespace, "the tenant reconcile must reach the handoff wait",
			func(mtc *unstructured.Unstructured) bool {
				return controllerutil.ContainsFinalizer(mtc, tenant.PraxisCleanupFinalizer)
			})
		installed, err := praxisInstalled(t.Context(), c, namespace)
		require.NoError(t, err)
		require.False(t, installed, "Praxis installed before the handoff signal")

		// When maas-controller signals that the legacy cleanup is complete.
		annotateTenantConfig(t, c, namespace, tenant.AnnotationPayloadProcessingStatus, tenant.PayloadProcessingStatusCleanupComplete)

		// Then the signal's own event installs Praxis; no requeue is due in time.
		awaitPraxisInstalledWithin(t, c, namespace, eventTimeout)
	})

	t.Run("a tenant blocked by a leftover IPP plugins ConfigMap installs Praxis once it is removed", func(t *testing.T) {
		// Given a leftover IPP plugins ConfigMap an operator has taken over,
		// left behind by a raced handoff.
		const namespace = "plugins-migration-gate"
		leftover := &corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{
				Name:        tenant.PayloadProcessingPluginsConfigMapForTenant(namespace),
				Namespace:   gatewayNamespace,
				Annotations: map[string]string{tenant.AnnotationManaged: "false"},
			},
			// The IPP post-processing key the migration gate recognises.
			Data: map[string]string{"custom-ipp-config.yaml": "kind: PayloadProcessorConfig\n"},
		}
		require.NoError(t, c.Create(t.Context(), leftover))
		maas := maasFixture{client: c}
		maas.existingPraxisTenant(t, namespace)

		// The handoff is claimed, but the gate refuses to overwrite the leftover.
		awaitTenantConfigState(t, c, namespace, "the tenant reconcile must claim the handoff",
			func(mtc *unstructured.Unstructured) bool {
				return mtc.GetAnnotations()[tenant.AnnotationPayloadProcessingStatus] == tenant.PayloadProcessingStatusSteady
			})
		assert.Never(t, func() bool {
			installed, err := praxisInstalled(t.Context(), c, namespace)
			return err != nil || installed
		}, time.Second, pollInterval, "Praxis installed over a leftover IPP plugins ConfigMap, or its Deployment could not be read")

		// When the operator removes the leftover.
		require.NoError(t, c.Delete(t.Context(), leftover))

		// Then its delete event installs Praxis; the gate has no requeue due.
		awaitPraxisInstalledWithin(t, c, namespace, eventTimeout)
	})
}

// The API server, not a fake client, validates the names rendered for each
// model (RHOAIENG-100314).
func TestModelNamesAreRenderedPerModel(t *testing.T) {
	c := startControlPlane(t)

	// Given an existing Praxis tenant with a configured provider.
	const namespace = "model-names"
	maas := maasFixture{client: c}
	maas.existingPraxisTenant(t, namespace)
	awaitPraxisInstalled(t, c, namespace)
	provider := createProvider(t, c, namespace)

	// When a user adds a model whose name is longer than a label value, and
	// one whose name has a dot, so it is not a valid Service name.
	long := externalModel(strings.Repeat("m", 64), namespace,
		withModelName("long"),
		withProviderModel(provider.Name, "provider-model"),
	)
	require.NoError(t, c.Create(t.Context(), long))
	model := externalModel("gpt-4.1", namespace,
		withModelName("gpt-4.1"),
		withProviderModel(provider.Name, "gpt-4.1"),
	)
	require.NoError(t, c.Create(t.Context(), model))

	// Then the dotted model is published, and only the long one fails.
	routeName := awaitModelPublished(t, c, model, provider)
	awaitModelFailed(t, c, long, "InvalidName")

	// When the user deletes both, their routing and workload are removed.
	require.NoError(t, c.Delete(t.Context(), long))
	require.NoError(t, c.Delete(t.Context(), model))
	awaitModelRemoved(t, c, long, "external-model-"+long.Name)
	awaitModelRemoved(t, c, model, routeName)
}
