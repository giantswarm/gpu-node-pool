# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- A pool node on the Giant Swarm Flatcar image reaches `nvidia.com/gpu` allocatable (#8): the bootstrap's `nvidia-cdi-spec.service`, ordered after Flatcar's `nvidia.service`, sets the image's NVIDIA container runtime to `mode = "cdi"` and writes the CDI specification of the driver to `/var/run/cdi/nvidia.yaml` with `/usr/bin` ahead of `/opt/bin` on its PATH. In `auto` mode the runtime located `nvidia-smi` through containerd's PATH (`/opt/bin` first on this image) and mounted it at `/opt/bin/nvidia-smi` in every container, off the PATH, so the GPU operator's toolkit validation looped on `nvidia-smi: executable file not found` and no GPU was ever advertised.
- The bootstrap diff against cluster-aws (`make verify`) whitelists single list elements (`files[path=…]`, `preKubeadmCommands[=…]`, `additionalConfig.systemd.units[name=…]`) and decodes the Ignition config, so an added unit no longer needs the whole `files` list or the whole Ignition config taken out of the comparison.

### Added

- The chart README states the image contract: what the Giant Swarm Flatcar image provides for GPUs (driver, container toolkit, containerd's `nvidia` runtime with CDI on) and what the pool configures.

[Unreleased]: https://github.com/giantswarm/gpu-node-pool/tree/main
