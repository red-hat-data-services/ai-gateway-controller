PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
LOCALBIN := $(PROJECT_DIR)/bin/tools

$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tools
GOLANGCI_LINT ?= $(LOCALBIN)/golangci-lint

GOLANGCI_LINT_VERSION ?= v2.12.2
# Target the versioned binary so version bumps trigger reinstall
$(GOLANGCI_LINT)-$(GOLANGCI_LINT_VERSION): $(LOCALBIN)
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/v2/cmd/golangci-lint,$(GOLANGCI_LINT_VERSION))
$(GOLANGCI_LINT): $(GOLANGCI_LINT)-$(GOLANGCI_LINT_VERSION)

CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
CONTROLLER_GEN_VERSION ?= v0.19.0
# Target the versioned binary so version bumps trigger reinstall
$(CONTROLLER_GEN)-$(CONTROLLER_GEN_VERSION): $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_GEN_VERSION))
$(CONTROLLER_GEN): $(CONTROLLER_GEN)-$(CONTROLLER_GEN_VERSION)

SETUP_ENVTEST ?= $(LOCALBIN)/setup-envtest
SETUP_ENVTEST_VERSION ?= v0.0.0-20260305142021-f9589b9f2b9d
$(SETUP_ENVTEST)-$(SETUP_ENVTEST_VERSION): $(LOCALBIN)
	$(call go-install-tool,$(SETUP_ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest,$(SETUP_ENVTEST_VERSION))
$(SETUP_ENVTEST): $(SETUP_ENVTEST)-$(SETUP_ENVTEST_VERSION)

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary (ideally with version)
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f $(1) || true ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv $(1) $(1)-$(3) ;\
} ;\
ln -sf $(1)-$(3) $(1)
endef
