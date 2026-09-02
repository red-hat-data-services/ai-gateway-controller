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

package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/opendatahub-io/ai-gateway-controller/pkg/render"
)

var setupLog = ctrl.Log.WithName("setup")

func main() {
	var (
		metricsAddr          string
		probeAddr            string
		enableLeaderElection bool
		namespace            string
		gatewayName          string
		image                string
		manifestPath         string
		maasAPIRouteName     string
		resyncInterval       time.Duration
	)

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "The address the metrics endpoint binds to.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "The address the probe endpoint binds to.")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false,
		"Enable leader election for controller manager. Enable this when running multiple replicas.")
	flag.StringVar(&namespace, "namespace", "openshift-ingress",
		"The namespace to install praxis-extproc into. Must match the Gateway's namespace "+
			"(--gateway-namespace on maas-controller) so EnvoyFilter workloadSelector / targetRefs resolve.")
	flag.StringVar(&gatewayName, "gateway-name", "maas-default-gateway",
		"The name of the Gateway resource praxis-extproc's EnvoyFilter targets.")
	flag.StringVar(&image, "image", "quay.io/opendatahub/odh-praxis-extproc:odh-stable",
		"Container image for the payload-processing and payload-pre-processing Deployments.")
	flag.StringVar(&manifestPath, "manifest-path", "/config/manifests/praxis-extproc/overlays/odh",
		"Path to the vendored praxis-extproc kustomize overlay.")
	flag.StringVar(&maasAPIRouteName, "maas-api-route-name", "maas-api-route",
		"Base name of maas-api's HTTPRoute, used to disable ext_proc on its own routes. "+
			"Exact fidelity depends on the Istio version's route-naming scheme; see DESIGN.md.")
	flag.DurationVar(&resyncInterval, "resync-interval", 5*time.Minute,
		"How often to re-render and re-apply the praxis-extproc manifests. This controller does not "+
			"watch any CR in Phase 1 (see DESIGN.md), so this interval is the only re-apply trigger "+
			"besides restart.")

	opts := zap.Options{}
	if err := applyLogDevelopment(&opts, os.Stderr); err != nil {
		os.Exit(1)
	}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	if namespace == "" || gatewayName == "" || image == "" {
		setupLog.Error(errors.New("missing required flag"), "--namespace, --gateway-name, and --image must be non-empty")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme: clientgoscheme.Scheme,
		Metrics: metricsserver.Options{
			BindAddress: metricsAddr,
		},
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "ai-gateway-controller-leader.opendatahub.io",
	})
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	installer := &render.Installer{
		Client:       mgr.GetClient(),
		ManifestPath: manifestPath,
		Params: render.Params{
			Namespace:        namespace,
			GatewayName:      gatewayName,
			Image:            image,
			MaaSAPIRouteName: maasAPIRouteName,
		},
		ResyncInterval: resyncInterval,
		Log:            ctrl.Log.WithName("installer"),
	}
	if err := mgr.Add(installer); err != nil {
		setupLog.Error(err, "unable to register installer")
		os.Exit(1)
	}

	setupLog.Info("starting ai-gateway-controller",
		"namespace", namespace, "gatewayName", gatewayName, "manifestPath", manifestPath, "image", image)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}

// applyLogDevelopment reads LOG_DEVELOPMENT into opts. Invalid values are
// written to errOut: ctrl.Log is a NullLogSink until SetLogger runs.
func applyLogDevelopment(opts *zap.Options, errOut io.Writer) error {
	v, ok := os.LookupEnv("LOG_DEVELOPMENT")
	if !ok {
		return nil
	}
	dev, err := strconv.ParseBool(v)
	if err != nil {
		fmt.Fprintf(errOut, "invalid LOG_DEVELOPMENT value %q: %v\n", v, err)
		return err
	}
	opts.Development = dev
	return nil
}
