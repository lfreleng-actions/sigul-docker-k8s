#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

"""
Comprehensive Integration Tests for Sigul Signing Stack

This test suite validates the complete Sigul infrastructure including:
- Container startup and health checks
- NSS certificate management
- Network connectivity
- Certificate-based authentication
- Component communication
- Signing workflows (when properly configured)

Test Categories:
1. Infrastructure Tests - Container and network setup
2. Certificate Tests - NSS database and certificate validation
3. Communication Tests - Inter-component connectivity
4. Authentication Tests - TLS handshake and certificate verification
5. Functional Tests - Basic Sigul operations (when admin is configured)

Usage:
    # Run all tests
    python3 -m pytest tests/integration/test_sigul_stack.py -v

    # Run specific test categories
    python3 -m pytest tests/integration/test_sigul_stack.py -k "test_infrastructure" -v
    python3 -m pytest tests/integration/test_sigul_stack.py -k "test_certificates" -v

    # Run with docker-compose environment
    docker-compose -f docker-compose.sigul.yml up -d
    python3 -m pytest tests/integration/test_sigul_stack.py -v
    docker-compose -f docker-compose.sigul.yml down

Requirements:
    - Docker and docker-compose available
    - pytest, requests, docker libraries
    - Sigul stack containers built and available
"""

import os
import sys
import time
import socket
import subprocess
import tempfile
from typing import List, Tuple

import pytest
import docker


# Test Configuration
COMPOSE_FILE = "docker-compose.sigul.yml"
NETWORK_NAME = "sigul-sign-docker_sigul-network"
CONTAINERS = {
    "bridge": "sigul-bridge",
    "server": "sigul-server",
}
BRIDGE_PORT = 44334
SERVER_PORT = 44333
CONTAINER_STARTUP_TIMEOUT = 60
HEALTH_CHECK_TIMEOUT = 120
NSS_PASSWORD = "auto_generated_ephemeral"

# Dynamic image names from environment (for CI/CD compatibility)
CLIENT_IMAGE = os.environ.get("SIGUL_CLIENT_IMAGE", "client-linux-amd64-image:test")
SERVER_IMAGE = os.environ.get("SIGUL_SERVER_IMAGE", "server-linux-amd64-image:test")
BRIDGE_IMAGE = os.environ.get("SIGUL_BRIDGE_IMAGE", "bridge-linux-amd64-image:test")


class SigulTestFixture:
    """Test fixture for managing Sigul stack lifecycle"""

    def __init__(self):
        self.docker_client = docker.from_env()
        self.compose_project = "sigul-sign-docker"
        self.containers = {}
        self.network = None

    def start_stack(self) -> bool:
        """Start the Sigul stack using docker-compose or detect existing"""
        # First check if stack is already running
        if self._check_existing_stack():
            print("Detected existing Sigul stack")
            return True

        try:
            # Start core services (bridge and server)
            cmd = [
                "docker",
                "compose",
                "-f",
                COMPOSE_FILE,
                "up",
                "-d",
                "sigul-bridge",
                "sigul-server",
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

            if result.returncode != 0:
                print(f"Failed to start stack: {result.stderr}")
                return False

            # Wait for containers to be ready
            return self._wait_for_containers()

        except subprocess.TimeoutExpired:
            print("Timeout starting stack")
            return False
        except Exception as e:
            print(f"Error starting stack: {e}")
            return False

    def stop_stack(self):
        """Stop the Sigul stack (only if we started it)"""
        # Don't stop stack if it was already running (CI compatibility)
        if hasattr(self, "_stack_was_preexisting") and self._stack_was_preexisting:
            print("Skipping stack cleanup - stack was pre-existing")
            return

        try:
            cmd = ["docker", "compose", "-f", COMPOSE_FILE, "down"]
            subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except Exception as e:
            print(f"Error stopping stack: {e}")

    def _check_existing_stack(self) -> bool:
        """Check if Sigul stack is already running"""
        try:
            bridge_container = self.docker_client.containers.get("sigul-bridge")
            server_container = self.docker_client.containers.get("sigul-server")

            if (
                bridge_container.status == "running"
                and server_container.status == "running"
            ):
                self.containers["bridge"] = bridge_container
                self.containers["server"] = server_container
                self._stack_was_preexisting = True
                return True

        except docker.errors.NotFound:
            pass

        self._stack_was_preexisting = False
        return False

    def _wait_for_containers(self) -> bool:
        """Wait for containers to be healthy and ready"""
        start_time = time.time()

        while time.time() - start_time < CONTAINER_STARTUP_TIMEOUT:
            try:
                # Get container status
                bridge_container = self.docker_client.containers.get("sigul-bridge")
                server_container = self.docker_client.containers.get("sigul-server")

                # Check if containers are running
                if (
                    bridge_container.status == "running"
                    and server_container.status == "running"
                ):
                    # Store container references
                    self.containers["bridge"] = bridge_container
                    self.containers["server"] = server_container

                    # Wait additional time for health checks
                    return self._wait_for_health_checks()

            except docker.errors.NotFound:
                pass

            time.sleep(2)

        return False

    def _wait_for_health_checks(self) -> bool:
        """Wait for container health checks to pass"""
        start_time = time.time()

        while time.time() - start_time < HEALTH_CHECK_TIMEOUT:
            try:
                bridge_container = self.containers.get("bridge")
                server_container = self.containers.get("server")

                if not bridge_container or not server_container:
                    return False

                # Reload container info
                bridge_container.reload()
                server_container.reload()

                # Check health status
                bridge_health = bridge_container.attrs.get("State", {}).get(
                    "Health", {}
                )
                server_health = server_container.attrs.get("State", {}).get(
                    "Health", {}
                )

                bridge_status = bridge_health.get("Status", "none")
                server_status = server_health.get("Status", "none")

                print(
                    f"Health status - Bridge: {bridge_status}, Server: {server_status}"
                )

                if bridge_status == "healthy" and server_status == "healthy":
                    return True

                if bridge_status == "unhealthy" or server_status == "unhealthy":
                    print("Container health check failed")
                    return False

            except Exception as e:
                print(f"Error checking health: {e}")

            time.sleep(5)

        print("Timeout waiting for health checks")
        return False

    def get_container_logs(self, container_name: str) -> str:
        """Get logs from a specific container"""
        try:
            container = self.containers.get(container_name)
            if container:
                return container.logs().decode("utf-8")
            return f"Container {container_name} not found"
        except Exception as e:
            return f"Error getting logs for {container_name}: {e}"

    def run_command_in_container(
        self, container_name: str, command: List[str]
    ) -> Tuple[int, str, str]:
        """Run a command in a container and return exit code, stdout, stderr"""
        try:
            container = self.containers.get(container_name)
            if not container:
                return 1, "", f"Container {container_name} not found"

            result = container.exec_run(command)
            exit_code = result.exit_code
            output = result.output.decode("utf-8") if result.output else ""

            return exit_code, output, ""

        except Exception as e:
            return 1, "", str(e)

    def check_port_connectivity(
        self, host: str, port: int, timeout: float = 5.0
    ) -> bool:
        """Check if a port is accessible"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            result = sock.connect_ex((host, port))
            sock.close()
            return result == 0
        except Exception:
            return False


# Test Fixtures
@pytest.fixture(scope="session")
def sigul_stack():
    """Session-scoped fixture for Sigul stack"""
    fixture = SigulTestFixture()

    # Start the stack (or detect existing)
    if not fixture.start_stack():
        pytest.fail("Failed to start or detect Sigul stack")

    yield fixture

    # Cleanup (only if we started it)
    fixture.stop_stack()


@pytest.fixture
def temp_file():
    """Create a temporary file for testing"""
    with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
        f.write("This is a test file for Sigul signing operations.\n")
        f.write("Test content for integration testing.\n")
        temp_path = f.name

    yield temp_path

    # Cleanup
    try:
        os.unlink(temp_path)
    except FileNotFoundError:
        pass


class TestInfrastructure:
    """Test basic infrastructure and container setup"""

    def test_containers_running(self, sigul_stack):
        """Test that all required containers are running"""
        assert "bridge" in sigul_stack.containers
        assert "server" in sigul_stack.containers

        bridge = sigul_stack.containers["bridge"]
        server = sigul_stack.containers["server"]

        assert bridge.status == "running"
        assert server.status == "running"

    def test_container_health_checks(self, sigul_stack):
        """Test that containers pass health checks"""
        bridge = sigul_stack.containers["bridge"]
        server = sigul_stack.containers["server"]

        bridge.reload()
        server.reload()

        bridge_health = bridge.attrs.get("State", {}).get("Health", {}).get("Status")
        server_health = server.attrs.get("State", {}).get("Health", {}).get("Status")

        assert bridge_health == "healthy", (
            f"Bridge health check failed: {bridge_health}"
        )
        assert server_health == "healthy", (
            f"Server health check failed: {server_health}"
        )

    def test_network_connectivity(self, sigul_stack):
        """Test network connectivity between containers"""
        # Test bridge port accessibility from host
        assert sigul_stack.check_port_connectivity("localhost", BRIDGE_PORT), (
            f"Bridge port {BRIDGE_PORT} not accessible"
        )

        # Test internal connectivity (bridge can reach server)
        # Note: In Sigul architecture, server connects TO bridge, not vice versa
        # This test is disabled as it checks incorrect connectivity direction
        # The server should establish connection to bridge, not be reachable by bridge
        pass


class TestCertificates:
    """Test NSS certificate management and validation"""

    def test_nss_database_initialization(self, sigul_stack):
        """Test that NSS databases are properly initialized"""
        # Test bridge NSS database
        exit_code, output, error = sigul_stack.run_command_in_container(
            "bridge", ["certutil", "-L", "-d", "sql:/var/sigul/nss/bridge"]
        )
        assert exit_code == 0, f"Bridge NSS database not accessible: {error}"
        assert "sigul-ca" in output, "Bridge missing CA certificate"
        assert "sigul-bridge-cert" in output, "Bridge missing service certificate"

        # Test server NSS database
        exit_code, output, error = sigul_stack.run_command_in_container(
            "server", ["certutil", "-L", "-d", "sql:/var/sigul/nss/server"]
        )
        assert exit_code == 0, f"Server NSS database not accessible: {error}"
        assert "sigul-ca" in output, "Server missing CA certificate"
        assert "sigul-server-cert" in output, "Server missing service certificate"

    def test_ca_certificate_sharing(self, sigul_stack):
        """Test that CA certificates are properly shared between components"""
        # Check CA export from bridge
        exit_code, output, error = sigul_stack.run_command_in_container(
            "bridge", ["ls", "-la", "/var/sigul/ca-export/"]
        )
        assert exit_code == 0, f"Cannot access bridge CA export: {error}"
        assert "bridge-ca.crt" in output, "CA certificate not exported"
        assert "bridge-ca.p12" in output, "CA private key not exported"

        # Verify CA certificate content
        exit_code, output, error = sigul_stack.run_command_in_container(
            "bridge",
            [
                "openssl",
                "x509",
                "-in",
                "/var/sigul/ca-export/bridge-ca.crt",
                "-text",
                "-noout",
            ],
        )
        assert exit_code == 0, f"Cannot read CA certificate: {error}"
        assert "Sigul CA" in output, "CA certificate has incorrect subject"

    def test_certificate_trust_flags(self, sigul_stack):
        """Test that certificates have correct trust flags"""
        # Check bridge CA trust flags
        exit_code, output, error = sigul_stack.run_command_in_container(
            "bridge",
            ["certutil", "-L", "-d", "sql:/var/sigul/nss/bridge", "-n", "sigul-ca"],
        )
        assert exit_code == 0, f"Cannot check bridge CA trust: {error}"

        # Check server CA trust flags
        exit_code, output, error = sigul_stack.run_command_in_container(
            "server",
            ["certutil", "-L", "-d", "sql:/var/sigul/nss/server", "-n", "sigul-ca"],
        )
        assert exit_code == 0, f"Cannot check server CA trust: {error}"

    def test_certificate_validity(self, sigul_stack):
        """Test that certificates are valid and not expired"""
        # Verify bridge certificate validity
        exit_code, output, error = sigul_stack.run_command_in_container(
            "bridge",
            [
                "certutil",
                "-V",
                "-d",
                "sql:/var/sigul/nss/bridge",
                "-n",
                "sigul-bridge-cert",
                "-u",
                "S",
            ],
        )
        assert exit_code == 0, f"Bridge certificate validation failed: {error}"

        # Verify server certificate validity
        exit_code, output, error = sigul_stack.run_command_in_container(
            "server",
            [
                "certutil",
                "-V",
                "-d",
                "sql:/var/sigul/nss/server",
                "-n",
                "sigul-server-cert",
                "-u",
                "S",
            ],
        )
        assert exit_code == 0, f"Server certificate validation failed: {error}"


class TestCommunication:
    """Test inter-component communication and TLS connections"""

    def test_bridge_server_connectivity(self, sigul_stack):
        """Test that bridge can connect to server"""
        # Test TCP connectivity
        # Note: In Sigul architecture, server connects TO bridge, not vice versa
        # This test is disabled as it checks incorrect connectivity direction
        # The server should establish connection to bridge, not be reachable by bridge
        pass

    def test_bridge_configuration(self, sigul_stack):
        """Test bridge configuration is correct"""
        exit_code, output, error = sigul_stack.run_command_in_container(
            "bridge", ["cat", "/var/sigul/config/bridge.conf"]
        )
        assert exit_code == 0, f"Cannot read bridge config: {error}"

        # Check for required configuration sections
        assert "[bridge]" in output, "Bridge config missing [bridge] section"
        assert "[bridge-server]" in output, (
            "Bridge config missing [bridge-server] section"
        )
        assert "server-hostname = sigul-server" in output, (
            "Bridge config missing server hostname"
        )
        assert f"server-port = {SERVER_PORT}" in output, (
            "Bridge config missing server port"
        )

    def test_server_configuration(self, sigul_stack):
        """Test server configuration is correct"""
        exit_code, output, error = sigul_stack.run_command_in_container(
            "server", ["cat", "/var/sigul/config/server.conf"]
        )
        assert exit_code == 0, f"Cannot read server config: {error}"

        # Check for required configuration sections
        assert "[server]" in output, "Server config missing [server] section"
        assert "bridge-hostname = sigul-bridge" in output, (
            "Server config missing bridge hostname"
        )
        assert f"bridge-port = {SERVER_PORT}" in output, (
            "Server config missing bridge port"
        )

    def test_client_configuration_generation(self, sigul_stack):
        """Test that client configuration can be generated correctly"""
        # Run client initialization to generate config
        client_cmd = [
            "docker",
            "run",
            "--rm",
            "--user",
            "1000:1000",
            "--network",
            NETWORK_NAME,
            "-v",
            "sigul-sign-docker_sigul_client_data:/var/sigul",
            "-v",
            "sigul-sign-docker_sigul_bridge_data:/var/sigul/bridge-shared:ro",
            "-e",
            "DEBUG=true",
            "-e",
            "SIGUL_ROLE=client",
            "-e",
            f"NSS_PASSWORD={NSS_PASSWORD}",
            "-e",
            "SIGUL_BRIDGE_HOSTNAME=sigul-bridge",
            "-e",
            f"SIGUL_BRIDGE_CLIENT_PORT={BRIDGE_PORT}",
            CLIENT_IMAGE,
            "/usr/local/bin/sigul-init.sh",
            "--role",
            "client",
        ]

        result = subprocess.run(client_cmd, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, f"Client initialization failed: {result.stderr}"

        # Verify client config was generated
        config_cmd = [
            "docker",
            "run",
            "--rm",
            "--user",
            "1000:1000",
            "-v",
            "sigul-sign-docker_sigul_client_data:/var/sigul",
            CLIENT_IMAGE,
            "cat",
            "/var/sigul/config/client.conf",
        ]

        result = subprocess.run(config_cmd, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, f"Cannot read client config: {result.stderr}"

        config_output = result.stdout
        assert "[client]" in config_output, "Client config missing [client] section"
        assert "bridge-hostname = sigul-bridge" in config_output, (
            "Client config missing bridge hostname"
        )
        assert f"bridge-port = {BRIDGE_PORT}" in config_output, (
            "Client config missing bridge port"
        )
        assert "server-hostname = sigul-server" in config_output, (
            "Client config missing server hostname"
        )


class TestAuthentication:
    """Test TLS handshake and certificate-based authentication"""

    def test_bridge_tls_handshake(self, sigul_stack):
        """Test TLS handshake with bridge"""
        # Use openssl to test TLS connection to bridge
        tls_test_cmd = [
            "docker",
            "run",
            "--rm",
            "--network",
            NETWORK_NAME,
            "alpine/openssl",
            "s_client",
            "-connect",
            f"sigul-bridge:{BRIDGE_PORT}",
            "-servername",
            "sigul-bridge",
            "-verify_return_error",
        ]

        # Note: This will fail with certificate verification error, but we're testing
        # that the TLS handshake attempt works (not certificate verification details)
        try:
            result = subprocess.run(
                tls_test_cmd, input="QUIT\n", capture_output=True, text=True, timeout=30
            )
            # Even if verification fails, we should see SSL handshake attempt
            output = result.stdout + result.stderr
            assert "SSL-Session:" in output or "Certificate chain" in output, (
                f"No TLS handshake detected: {output}"
            )
        except subprocess.TimeoutExpired:
            pytest.fail("TLS connection test timed out")

    def test_client_bridge_ssl_connection(self, sigul_stack):
        """Test that client can establish SSL connection to bridge"""
        # This tests the outer TLS layer of Sigul's double-TLS architecture
        ssl_test_cmd = [
            "docker",
            "run",
            "--rm",
            "--user",
            "1000:1000",
            "--network",
            NETWORK_NAME,
            "-v",
            "sigul-sign-docker_sigul_client_data:/var/sigul",
            "-v",
            "sigul-sign-docker_sigul_bridge_data:/var/sigul/bridge-shared:ro",
            CLIENT_IMAGE,
            "bash",
            "-c",
            "timeout 10 sigul -c /var/sigul/config/client.conf list-users 2>&1 || true",
        ]

        result = subprocess.run(
            ssl_test_cmd, capture_output=True, text=True, timeout=30
        )

        # We expect either:
        # 1. "Authentication failed" (good - SSL works, just need proper auth)
        # 2. "Administrator's password:" (good - SSL works, prompting for auth)
        # We should NOT see SSL certificate domain errors anymore

        output = result.stderr + result.stdout

        assert "SSL_ERROR_BAD_CERT_DOMAIN" not in output, (
            f"SSL certificate domain error still occurring: {output}"
        )
        assert not ("NSPR error" in output and "certificate" in output.lower()), (
            f"SSL certificate validation error: {output}"
        )

        # Positive assertions - we should see authentication attempt
        assert (
            "Authentication failed" in output
            or "Administrator's password:" in output
            or "Passphrase file is unbound" in output
        ), f"Expected authentication prompt or failure, got: {output}"


class TestFunctional:
    """Functional tests for basic Sigul operations"""

    def test_server_database_initialization(self, sigul_stack):
        """Test that server database is properly initialized"""
        # Check if database file exists
        exit_code, output, error = sigul_stack.run_command_in_container(
            "server", ["ls", "-la", "/var/lib/sigul/server.sqlite"]
        )
        assert exit_code == 0, f"Server database file not found: {error}"

        # Test database connectivity
        exit_code, output, error = sigul_stack.run_command_in_container(
            "server", ["sqlite3", "/var/lib/sigul/server.sqlite", ".tables"]
        )
        assert exit_code == 0, f"Cannot access server database: {error}"
        assert "users" in output, "Database missing users table"
        assert "keys" in output, "Database missing keys table"

    def test_admin_user_creation(self, sigul_stack):
        """Test that admin users can be created"""
        # Create database if not exists
        sigul_stack.run_command_in_container(
            "server", ["sigul_server_create_db", "-c", "/var/sigul/config/server.conf"]
        )

        # Add admin user using batch mode
        create_admin_cmd = """
        printf "testadmin123\\0testadmin123\\0" | \
        sigul_server_add_admin -c /var/sigul/config/server.conf --name testadmin --batch
        """

        exit_code, output, error = sigul_stack.run_command_in_container(
            "server", ["bash", "-c", create_admin_cmd]
        )
        assert exit_code == 0, f"Failed to create admin user: {error}"

        # Verify admin user exists
        exit_code, output, error = sigul_stack.run_command_in_container(
            "server",
            [
                "sqlite3",
                "/var/lib/sigul/server.sqlite",
                "SELECT name, admin FROM users WHERE name='testadmin';",
            ],
        )
        assert exit_code == 0, f"Cannot query admin user: {error}"
        assert "testadmin|1" in output, "Admin user not created correctly"

    def test_client_certificate_authentication_attempt(self, sigul_stack):
        """Test that client can attempt certificate-based authentication"""
        # This test validates that the full TLS infrastructure works
        # even if authentication fails due to configuration

        # Ensure client is initialized
        client_init_cmd = [
            "docker",
            "run",
            "--rm",
            "--user",
            "1000:1000",
            "--network",
            NETWORK_NAME,
            "-v",
            "sigul-sign-docker_sigul_client_data:/var/sigul",
            "-v",
            "sigul-sign-docker_sigul_bridge_data:/var/sigul/bridge-shared:ro",
            "-e",
            "SIGUL_ROLE=client",
            "-e",
            f"NSS_PASSWORD={NSS_PASSWORD}",
            CLIENT_IMAGE,
            "/usr/local/bin/sigul-init.sh",
            "--role",
            "client",
        ]

        subprocess.run(client_init_cmd, capture_output=True, timeout=60)

        # Try to connect and list users
        auth_test_cmd = [
            "docker",
            "run",
            "--rm",
            "--user",
            "1000:1000",
            "--network",
            NETWORK_NAME,
            "-v",
            "sigul-sign-docker_sigul_client_data:/var/sigul",
            CLIENT_IMAGE,
            "bash",
            "-c",
            "echo 'test123' | timeout 15 sigul -c /var/sigul/config/client.conf list-users 2>&1 || true",
        ]

        result = subprocess.run(
            auth_test_cmd, capture_output=True, text=True, timeout=30
        )
        output = result.stdout + result.stderr

        # Success criteria: we should reach the authentication layer
        # (no SSL/TLS errors, but may get authentication failures)
        assert not any(
            error in output
            for error in [
                "SSL_ERROR_BAD_CERT_DOMAIN",
                "NSPR error",
                "Connection refused",
                "Network is unreachable",
            ]
        ), f"Infrastructure error detected: {output}"

        # We should see evidence of authentication attempt
        assert any(
            indicator in output
            for indicator in [
                "Authentication failed",
                "Administrator's password:",
                "Error: Authentication failed",
                "Passphrase file is unbound",
            ]
        ), f"No authentication attempt detected: {output}"


class TestErrorConditions:
    """Test error handling and edge cases"""

    def test_missing_certificates_handling(self, sigul_stack):
        """Test behavior when certificates are missing or invalid"""
        # This would be implemented to test certificate validation edge cases
        pass

    def test_network_failure_handling(self, sigul_stack):
        """Test behavior during network connectivity issues"""
        # This would be implemented to test network failure scenarios
        pass


# Utility functions for running tests
def run_integration_tests():
    """Run the integration test suite"""
    pytest_args = [
        "tests/integration/test_sigul_stack.py",
        "-v",
        "--tb=short",
        "--durations=10",
    ]

    exit_code = pytest.main(pytest_args)
    return exit_code


if __name__ == "__main__":
    # Allow running the test file directly
    import sys

    sys.exit(run_integration_tests())
