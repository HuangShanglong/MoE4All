# Linux — build from source, launcher, and platform notes

The release archives are Windows-only. On Linux, build from source. This page is
the long form of the README's Linux section.

## Prerequisites

- **Rust** — `rust-toolchain.toml` pins **1.97.1** (with `rustfmt` + `clippy`);
  `rustup` installs it automatically on the first build.
- **`glslc` (shaderc)** — the compute shaders are compiled at build time. The
  dp4a shaders need `GL_EXT_integer_dot_product`, so the compiler must be
  **shaderc 2025 or newer**. Ubuntu 24.04 ships shaderc 2023.8, which is too
  old; Ubuntu 26.04 ships a usable one. This is also why CI pins
  `ubuntu-26.04`.
- **A Vulkan driver is needed to run, not to build** — `ash` loads `libvulkan`
  at runtime via `dlopen`. On AMD that means RADV (Mesa) or AMDVLK.

## Build

```sh
sudo apt-get update && sudo apt-get install -y glslc
git clone https://github.com/Headmaster218/MoE4All.git
cd MoE4All
cargo build --release --locked -p infr-cli
```

The binary lands at `target/release/infr`.

`.cargo/config.toml` sets `-C target-cpu=native`, because the CPU backend leans
on that to autovectorize its scalar dequant/matvec loops. The resulting binary is
therefore specific to the build machine's ISA — override the setting when
distributing across machines.

## Run

[`Start-INFR-Wizard-Linux.sh`](../Start-INFR-Wizard-Linux.sh) covers the common
workflow:

```sh
./Start-INFR-Wizard-Linux.sh
```

It walks through the mode (terminal chat / OpenAI-compatible API / benchmark),
model selection, the profile (`aggressive` / `conservative` / `manual`), the
manual knobs (context, ubatch, KV format, RAM and VRAM budgets), MTP, the listen
address and parallel slots, and the vision projector / embedding model. It
prints the final command and asks for confirmation before launching, and it
remembers the previous selections under
`${XDG_CONFIG_HOME:-~/.config}/infr/wizard.conf`.

`--dry-run` prints the command without launching, and works without a TTY so it
is scriptable; every prompt can also be answered from the command line:

```sh
./Start-INFR-Wizard-Linux.sh --dry-run --mode serve --model m.gguf \
    --profile aggressive --addr 127.0.0.1:8080 --parallel 1
```

The launcher is a thin front end for the CLI, which you can also drive directly:

```sh
./target/release/infr devices               # list visible Vulkan devices + VRAM
./target/release/infr run   <model>         # terminal chat
./target/release/infr serve <model>         # OpenAI-compatible API
```

`<model>` may be a local `.gguf` path or a Hugging Face reference
(`org/repo[:quant]`). **Only the latter is auto-downloaded when missing — a local
path is not.**

## Notes

- **The GPU integration tests are `#[ignore]`d** — they need a real Vulkan
  device, so the default `cargo test` skips them (which is what CI does). To run
  them:

  ```sh
  cargo test --workspace --locked -- --include-ignored
  ```

- **Large MoE host tiers and the GPU aperture.** A paged MoE model can map a host
  tier into the GPU's address space. On AMD that aperture is bounded by the GTT,
  whose size is fixed when the `amdgpu` module initializes:

  ```
  # /etc/modprobe.d/amdgpu-gtt.conf
  options amdgpu gttsize=<MiB>
  ```

  It takes effect at module load (a reboot), not at runtime. When raising it,
  keep the tier within physical RAM — the host tier, the page cache and the model
  itself all have to fit.

## See also

- [Configuration reference](config.md)
- [Performance notes](perf/README.md)
