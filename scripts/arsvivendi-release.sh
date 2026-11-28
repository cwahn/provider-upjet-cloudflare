#!/usr/bin/env bash
# Called by publish-arsvivendi.yml on GitHub-hosted runners.
set -euo pipefail

version=${GITHUB_REF_NAME:?}
arch=${BUILD_ARCH:?}
version_regex='^v[0-9]+\.[0-9]+\.[0-9]+-arsvivendi\.[0-9]+$'
[[ "$version" =~ $version_regex ]]
[[ "$arch" == amd64 || "$arch" == arm64 ]]

workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT

output="$PWD/_output/arsvivendi"
registry=ghcr.io/cwahn
groups=(config api d1 dns r2 workers zero)

repo_for() {
    if [[ "$1" == config ]]; then
        echo provider-family-cloudflare
    else
        echo "provider-cloudflare-$1"
    fi
}

install_crossplane() {
    local url="https://releases.crossplane.io/stable/${CROSSPLANE_VERSION:?}/bin/linux_${arch}/crossplane"
    local sha
    case "$CROSSPLANE_VERSION/$arch" in
        v2.4.2/amd64) sha=943bf9c8507771e29978611d2f9f8d73be35e7e57b62f48235bb181b6fbe6d33 ;;
        v2.4.2/arm64) sha=7a3296b3489c24ddbe6d5b9121cdf4e50905034dda38b412f6220f7548928057 ;;
        *) echo "No pinned Crossplane CLI checksum for $CROSSPLANE_VERSION/$arch" >&2; exit 1 ;;
    esac
    curl -fsSL --retry 3 "$url" -o "$workspace/crossplane"
    printf '%s  %s\n' "$sha" "$workspace/crossplane" | sha256sum -c -
    chmod 0755 "$workspace/crossplane"
}

build() {
    local context="$workspace/image" group repo image
    mkdir -p "$context/bin/linux_${arch}"
    cp cluster/images/provider-upjet-cloudflare/{Dockerfile,terraformrc.hcl} "$context/"

    for group in "${groups[@]}"; do
        repo=$(repo_for "$group")
        image="arsvivendi-local/${repo}-${arch}"
        CGO_ENABLED=0 go build -mod=readonly -trimpath \
            -ldflags "-X github.com/wildbitca/provider-upjet-cloudflare/internal/version.Version=$version -s -w" \
            -o "$context/bin/linux_${arch}/$group" "./cmd/provider/$group"
        docker buildx build --load --platform "linux/$arch" --tag "$image" \
            --label 'org.opencontainers.image.source=https://github.com/cwahn/provider-upjet-cloudflare' \
            --label "org.opencontainers.image.revision=${GITHUB_SHA:?}" \
            --build-arg "SUBPACKAGE=$group" \
            --build-arg "OPENTOFU_VERSION=${OPENTOFU_VERSION:?}" \
            --build-arg TERRAFORM_PROVIDER_SOURCE=cloudflare/cloudflare \
            --build-arg "TERRAFORM_PROVIDER_VERSION=${TERRAFORM_PROVIDER_VERSION:?}" \
            --build-arg TERRAFORM_PROVIDER_DOWNLOAD_NAME=terraform-provider-cloudflare \
            --build-arg "TERRAFORM_PROVIDER_DOWNLOAD_URL_PREFIX=https://github.com/cloudflare/terraform-provider-cloudflare/releases/download/v${TERRAFORM_PROVIDER_VERSION}" \
            --build-arg "TERRAFORM_NATIVE_PROVIDER_BINARY=terraform-provider-cloudflare_v${TERRAFORM_PROVIDER_VERSION}" \
            "$context"
        [[ "$(docker image inspect --format '{{.Architecture}}' "$image")" == "$arch" ]]
        if ! docker run --rm --network none "$image" --enable-secret-cache=false --help >"$workspace/help" 2>&1; then
            cat "$workspace/help" >&2
            return 1
        fi
        grep -F -- 'enable-secret-cache' "$workspace/help"
        bash scripts/build-family.sh "$group" "$version" "$output" "$workspace/crossplane" \
            arsvivendi-local "$arch" "linux_$arch"
        rm "$context/bin/linux_${arch}/$group"
        docker image rm "$image"
    done
}

publish() {
    local group repo target filename
    local -a paths
    for group in "${groups[@]}"; do
        repo=$(repo_for "$group")
        target="$registry/$repo:$version"
        filename="$repo-$version.xpkg"
        [[ -s "$output/artifacts/xpkgs-amd64/$filename" ]]
        [[ -s "$output/artifacts/xpkgs-arm64/$filename" ]]
        if docker buildx imagetools inspect "$target" >"$workspace/inspect" 2>&1; then
            echo "Refusing to overwrite existing release: $target" >&2
            exit 1
        elif ! grep -Eiq 'manifest unknown|: not found$' "$workspace/inspect"; then
            cat "$workspace/inspect" >&2
            exit 1
        fi
    done
    for group in "${groups[@]}"; do
        repo=$(repo_for "$group")
        target="$registry/$repo:$version"
        filename="$repo-$version.xpkg"
        paths=("$output/artifacts/xpkgs-amd64/$filename" "$output/artifacts/xpkgs-arm64/$filename")
        "$workspace/crossplane" xpkg push -f "${paths[0]},${paths[1]}" "$target"
        docker buildx imagetools inspect --raw "$target" | jq -e '
            ([.manifests[].platform | [.os, .architecture]] | sort) ==
            [["linux", "amd64"], ["linux", "arm64"]]'
        docker buildx imagetools inspect "$target" | tee -a "$GITHUB_STEP_SUMMARY"
    done
}

case "${1:-}" in
    build) install_crossplane; build ;;
    publish) install_crossplane; publish ;;
    *) echo 'Usage: arsvivendi-release.sh build|publish' >&2; exit 2 ;;
esac
