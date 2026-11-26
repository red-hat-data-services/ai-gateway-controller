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
	"context"
	"errors"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	// AnnotationForcePayloadProcessingMigration mirrors maas-controller's
	// tenantreconcile.AnnotationForcePayloadProcessingMigration (RHOAIENG-98846).
	// When "true" on MaasTenantConfig, this controller may overwrite a leftover
	// IPP-shaped plugins ConfigMap during Praxis apply.
	AnnotationForcePayloadProcessingMigration = "maas.opendatahub.io/force-payload-processing-migration"

	ippPreProcessingConfigKey = "custom-pre-processing-ipp-config.yaml"
	ippProcessingConfigKey    = "custom-ipp-config.yaml"

	// reasonPluginsMigrationRefused is the Warning event reason on a
	// MaasTenantConfig whose Praxis apply the migration gate refuses.
	reasonPluginsMigrationRefused = "PluginsMigrationRefused"
	applyPraxisAction             = "ApplyPraxis"
)

// errForceMigrationRevoked is the force annotation the pass acted on having
// been removed before the gate ran.
var errForceMigrationRevoked = errors.New(AnnotationForcePayloadProcessingMigration + " was removed during this reconcile")

// pluginsMigrationRefusedError is the gate refusing an overwrite, as opposed to
// failing to read the live ConfigMap. It carries the version that refused, so
// the caller can tell whether the informer has seen it.
type pluginsMigrationRefusedError struct {
	key             client.ObjectKey
	resourceVersion string
}

func (e *pluginsMigrationRefusedError) Error() string {
	return fmt.Sprintf(
		"live IPP-shaped plugins ConfigMap %s still present; refusing Praxis overwrite without %s=true (maas-controller should gate/cleanup first)",
		e.key, AnnotationForcePayloadProcessingMigration,
	)
}

// ensurePluginsConfigMapMigrationAllowed is defense-in-depth for RHOAIENG-98846.
// maas-controller owns the primary gate (fingerprint known-good baselines before
// IPP cleanup). If an IPP-shaped plugins ConfigMap is somehow still present when
// this controller is about to apply Praxis, refuse the overwrite unless the
// operator set the force annotation — so custom plugin edits are not silently
// replaced after a partial or raced handoff.
func (r *Reconciler) ensurePluginsConfigMapMigrationAllowed(
	ctx context.Context,
	mtc *unstructured.Unstructured,
	gatewayNamespace, tenantID string,
) error {
	// The pass chose its apply set from the force annotation it read at its
	// start: under force, a released IPP plugins ConfigMap is kept for
	// overwrite (omitUnmanagedReleasedPluginConfigMaps). The overwrite cannot
	// be undone, so confirm the operator has not revoked force since, whatever
	// the ConfigMap holds now. A revocation fails the pass; its retry, or the
	// annotation update, recomputes the apply set from the current object.
	if forcePayloadProcessingMigration(mtc) {
		live := NewMaasTenantConfig()
		if err := r.APIReader.Get(ctx, client.ObjectKeyFromObject(mtc), live); err != nil {
			return fmt.Errorf("re-read MaasTenantConfig %s for %s: %w", client.ObjectKeyFromObject(mtc), AnnotationForcePayloadProcessingMigration, err)
		}
		if !forcePayloadProcessingMigration(live) {
			return fmt.Errorf("MaasTenantConfig %s: %w", client.ObjectKeyFromObject(mtc), errForceMigrationRevoked)
		}
		return nil
	}

	cm := &corev1.ConfigMap{}
	key := client.ObjectKey{
		Namespace: gatewayNamespace,
		Name:      PayloadProcessingPluginsConfigMapForTenant(tenantID),
	}
	// Read live from the API server, not the informer cache: a cache-backed
	// Get can lag and return stale NotFound or Praxis-shaped data while the
	// live ConfigMap still holds IPP keys. That would let this guard pass and
	// render.Apply ForceOwnership-overwrite the IPP config. APIReader must be
	// wired (see Reconciler.APIReader); reads fail rather than silently degrade.
	if err := r.APIReader.Get(ctx, key, cm); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return fmt.Errorf("get plugins ConfigMap %s/%s: %w", key.Namespace, key.Name, err)
	}
	if !isIPPPluginsConfigMapData(cm.Data) {
		return nil
	}
	return &pluginsMigrationRefusedError{key: key, resourceVersion: cm.ResourceVersion}
}

func forcePayloadProcessingMigration(mtc *unstructured.Unstructured) bool {
	if mtc == nil {
		return false
	}
	ann := mtc.GetAnnotations()
	return ann != nil && ann[AnnotationForcePayloadProcessingMigration] == "true"
}

func isIPPPluginsConfigMapData(data map[string]string) bool {
	if data == nil {
		return false
	}
	_, hasPre := data[ippPreProcessingConfigKey]
	_, hasPost := data[ippProcessingConfigKey]
	return hasPre || hasPost
}
