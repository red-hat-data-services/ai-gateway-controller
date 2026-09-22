package controller

import (
	"errors"
	"fmt"
	"net/url"
	"strings"
)

type providerEndpoint struct {
	authority string
	host      string
	port      int64
}

// parseProviderEndpoint validates the ExternalProvider endpoint and separates
// the HTTP authority, dial port, and TLS SNI. The endpoint is a host or
// host:port, never a URL; SNI intentionally contains only the hostname.
func parseProviderEndpoint(endpoint string) (providerEndpoint, error) {
	endpoint = strings.TrimSpace(endpoint)
	if endpoint == "" {
		return providerEndpoint{}, errors.New("provider endpoint is required")
	}
	if strings.ContainsAny(endpoint, " /\t\r\n") || strings.Contains(endpoint, "://") {
		return providerEndpoint{}, fmt.Errorf("provider endpoint %q must be a host or host:port", endpoint)
	}
	parsed, err := url.Parse("https://" + endpoint)
	if err != nil || parsed.User != nil || parsed.Hostname() == "" || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return providerEndpoint{}, fmt.Errorf("provider endpoint %q must be a host or host:port", endpoint)
	}
	port := int64(443)
	if parsed.Port() != "" {
		var parsedPort int
		if _, err := fmt.Sscanf(parsed.Port(), "%d", &parsedPort); err != nil || parsedPort < 1 || parsedPort > 65535 {
			return providerEndpoint{}, fmt.Errorf("provider endpoint %q has an invalid port", endpoint)
		}
		port = int64(parsedPort)
	}
	return providerEndpoint{authority: parsed.Host, host: parsed.Hostname(), port: port}, nil
}

func validateProviderEndpoint(endpoint string) error {
	_, err := parseProviderEndpoint(endpoint)
	return err
}
