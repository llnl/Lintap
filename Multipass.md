# Building a Lintap-ready Ubuntu

These instructions cover building an Ubuntu VM on your local system that is usable for current Wintap/Lintap eBPF development, validation harness work, and legacy Sysdig-based experiments.

The basic premise is to use your local disk and system as much as possible, and the Ubuntu instance to run the sensor and collect data.

## Pre-requisites
* Install and run [Multipass](https://canonical.com/multipass) with a default image.
* Clone repos for Wintap, Lintap, and Wintap-Analytics under a shared parent directory.
```sh
mkdir -p ~/git/LLNL
cd ~/git/LLNL
git clone https://github.com/LLNL/Lintap.git
git clone https://github.com/LLNL/Wintap.git wintap
git clone <Wintap-Analytics-remote> Wintap-Analytics
```
* Build the Lintap VM
```sh
cd ~/git/LLNL/Lintap
cp multipass-config.env.example multipass-config.env
# Edit and set mounts appropriate for your system
./multipass-lintap.sh
```

Much whirring will occur as the VM is brought up and configured. Something could go wrong... check the cloud-init YAML that is embedded in the script to help debug.

Both provisioning scripts install SDK **10.0.402** in stable host-local
`/opt/wintap-sdk/10.0.402` and expose it on PATH. This includes .NET/ASP.NET Core 10;
it does not install a distribution-selected SDK patch. Package builders additionally
check the Wintap checkout's `global.json` before any cleanup/build work.

Once complete, you can connect with:

```sh
# Connect using multipass as the Ubuntu user. Uses the generated ssh-key and should always work.
multipass shell lintap-dev
# Connect with ssh, which uses your ~/.ssh/id_ed25519 key and connects as ubuntu. This is also what VS Code will use.
ssh lintap-dev
```

## Recommended mount layout

For current validation work, mount your local LLNL checkout root into `/home/ubuntu/git`:

```sh
MOUNTS=(
    "${HOME}/git/LLNL:/home/ubuntu/git"
    "${HOME}/data/lintap:/home/ubuntu/data/lintap"
)
```

With that layout, paths inside the VM are:

```text
/home/ubuntu/git/wintap
/home/ubuntu/git/Lintap
/home/ubuntu/git/Wintap-Analytics
```

## Useful commands inside the VM

Build Wintap/Lintap:

```sh
cd /home/ubuntu/git/wintap/wintap
make build_ebpf
make build_dotnet
```

Run the Lintap process smoke test:

```sh
cd /home/ubuntu/git/wintap
sudo python3 devtools/process_capture_smoke_test.py \
  --start-lintap \
  --lintap-dll /home/ubuntu/git/wintap/wintap/bin/Debug/net10.0/Lintap.dll \
  --timeout 240 \
  --poll-interval 5
```

Run the Wintap-Analytics validation harness mock tests:

```sh
cd /home/ubuntu/git/Wintap-Analytics/validation/process-creation
uv run --extra dev pytest
uv run wpv-mock-run --run-dir /tmp/validation-runs/wpv-mock --run-id multipass-mock
```

## Optional script controls

`multipass-config.env` can set:

```sh
WINTAP_BRANCH="grantj-ebf-fixes"
CHECKOUT_WINTAP_BRANCH=false
RUN_POSTCREATE_CHECKS=true
BUILD_WINTAP=false
RUN_VALIDATION_MOCKS=false
```

Keep `BUILD_WINTAP=false` for fast VM creation. Set it to `true` when you want the script to build eBPF and .NET immediately after cloud-init finishes.
