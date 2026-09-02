# Host-side only. Armbian copies the host's nameservers into `docker run --dns ...`. On WSL2 + Docker
# Desktop the host resolver (10.255.255.254) is unreachable from containers, so apt inside the build
# container fails with "Temporary failure resolving". Replace it with public resolvers.
# KERNEL_DOCKER_DNS="" disables this (scripts/build-kernel.sh passes it through).

function host_pre_docker_launch__public_dns() {
	[[ -z "${KERNEL_DOCKER_DNS:-}" ]] && return 0
	declare -a _kept=()
	declare _skip_next="no" _arg
	for _arg in "${DOCKER_ARGS[@]}"; do
		if [[ "${_skip_next}" == "yes" ]]; then _skip_next="no"; continue; fi
		if [[ "${_arg}" == "--dns" ]]; then _skip_next="yes"; continue; fi
		_kept+=("${_arg}")
	done
	DOCKER_ARGS=("${_kept[@]}")
	declare _dns
	for _dns in ${KERNEL_DOCKER_DNS}; do
		DOCKER_EXTRA_ARGS+=("--dns" "${_dns}")
	done
	display_alert "Container DNS overridden" "${KERNEL_DOCKER_DNS}" "info"
}
