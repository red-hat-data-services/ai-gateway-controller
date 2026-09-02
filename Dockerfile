ARG GOLANG_VERSION=1.26

ARG BUILDPLATFORM
ARG TARGETPLATFORM

FROM --platform=$BUILDPLATFORM registry.access.redhat.com/ubi9/go-toolset:$GOLANG_VERSION AS builder
ARG CGO_ENABLED=1
ARG GOEXPERIMENT=strictfipsruntime
ARG TARGETOS
ARG TARGETARCH

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ cmd/
COPY pkg/ pkg/

USER root

RUN CGO_ENABLED=${CGO_ENABLED} GOEXPERIMENT=${GOEXPERIMENT} GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} go build -a -trimpath -ldflags="-s -w" -o manager ./cmd/manager

FROM --platform=$TARGETPLATFORM registry.access.redhat.com/ubi9/ubi-minimal:latest

WORKDIR /

COPY --from=builder /app/manager /manager
RUN chmod +x /manager

# Vendored by hack/scripts/get-manifests.sh (see "make get-manifests"); must be
# present in the build context before "docker build" — this Dockerfile does not
# fetch it itself so image builds stay reproducible from a pinned checkout.
COPY config/manifests/praxis-extproc /config/manifests/praxis-extproc
RUN chmod -R g=u /config

# Use a non-root user (OpenShift will assign random UID)
USER 1001

ENTRYPOINT ["/manager"]
