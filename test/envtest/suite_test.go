//go:build envtest

package envtest_test

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/controller"
	"github.com/opendatahub-io/ai-gateway-controller/pkg/tenant"
)

const (
	repoRoot            = "../.."
	controllerNamespace = "opendatahub"
	maasNamespace       = "ai-tenants"
	eventuallyTimeout   = 15 * time.Second
	pollInterval        = 50 * time.Millisecond
)

// The AITenant's gateway differs from the model controller's default flags,
// so published routes must follow status.gatewayRef.
const (
	gatewayName      = "tenant-gateway"
	gatewayNamespace = "tenant-gateways"
)

// startControlPlane registers both controllers as cmd/manager does. Scenarios use
// the returned admin client to act as users and as the external MaaS controller.
//
//nolint:ireturn // controller-runtime exposes clients through client.Client.
func startControlPlane(t *testing.T) client.Client {
	t.Helper()
	return startEnvironment(t, func(mgr ctrl.Manager) {
		tenantController := &tenant.Reconciler{
			Client:               mgr.GetClient(),
			APIReader:            mgr.GetAPIReader(),
			ManifestPath:         filepath.Join(repoRoot, "config/manifests/external-model/overlays/odh"),
			Image:                "quay.io/example/praxis-extproc:test",
			MaaSAPIRouteNameBase: "maas-api-route",
			ResyncInterval:       time.Minute,
			Log:                  mgr.GetLogger().WithName("tenant"),
		}
		require.NoError(t, tenantController.SetupWithManager(mgr))
		modelController := &controller.Reconciler{
			Client:           mgr.GetClient(),
			APIReader:        mgr.GetAPIReader(),
			Scheme:           mgr.GetScheme(),
			GatewayName:      "maas-default-gateway",
			GatewayNamespace: "openshift-ingress",
			Network:          "external-model",
			Log:              mgr.GetLogger().WithName("external-model"),
		}
		require.NoError(t, modelController.SetupWithManager(mgr))
	})
}
