<!-- Author: Lei Zhao <lei1.zhao@sk.com> -->

# Solab server inventory

**Last updated: 2026-07-18.**

This is a snapshot, not live state. Verify the target host before use;
`unknown` means unverified.

| Name | Management IP | RDMA / data IP | CPU | GPU | Notes |
| --- | --- | --- | --- | --- | --- |
| `s1` | `192.168.3.61` | `192.168.5.61` (100GbE RoCE, `mlx5_1`) | unknown | 1x NVIDIA RTX A6000 48 GB | NFS server; verify the active Device-DAX window before CXL work |
| `s2` | `192.168.3.62` | `192.168.5.62` (100GbE RoCE, `mlx5_1`) | unknown | 1x NVIDIA RTX A6000 48 GB | CXL/RDMA peer of s1 |
| `s6` | `192.168.3.66:2022` | `192.168.5.66` (100GbE RoCE, `mlx5_0`) | unknown | 1x NVIDIA RTX A6000 48 GB | Four-host cuGraph/NCCL node |
| `s7` | `192.168.3.67:2022` | `192.168.5.67` (100GbE RoCE, `mlx5_0`) | unknown | 1x NVIDIA RTX A6000 48 GB | Four-host cuGraph/NCCL node |
| `x1` | `192.168.3.81` | unknown | 2x AMD EPYC 9555, 64 cores/socket | unknown | Dell PowerEdge XE7745 |
| `x3` | `192.168.3.73` | unknown | unknown | 4x NVIDIA H200 NVL, about 141 GB each | Hosts the TP4 Qwen3-Coder OpenAI-compatible API on port 8000 |
| `gnr2` | `192.168.3.92` | `100.10.10.192`, `200.10.10.192` (two 100GbE RoCE rails) | unknown | 1x NVIDIA A100 SXM4 80 GB | Dual-rail RoCE node |
| `gnr3` | `192.168.3.93` | `100.10.10.193`, `200.10.10.193` (two 100GbE RoCE rails) | unknown | 1x NVIDIA A100 PCIe 80 GB | Preflight both RDMA rails before distributed workloads |
| `amd2` | `192.168.3.64` | unknown | 2x AMD EPYC 9375F, 32 cores/socket | 1x NVIDIA A100 PCIe 80 GB | Dell PowerEdge R7725; CXL expander/Device-DAX work |

## Network rules

- `192.168.3.0/24` is the management/control network.
- NFS clients always mount s1 storage through `192.168.3.61` for stability.
- s1/s2/s6/s7 bulk distributed work should use the matched
  `192.168.5.0/24` 100GbE RoCE addresses, never silently fall back to the
  management network.
- gnr2/gnr3 bulk work should use one matched rail at a time:
  `100.10.10.193 <-> 100.10.10.192` or
  `200.10.10.193 <-> 200.10.10.192`, with MTU/link/RDMA state verified first.

## X3 LLM service

| Field | Current value |
| --- | --- |
| API | `http://192.168.3.73:8000/v1` |
| Model ID | `Qwen3-Coder-480B-A35B-Instruct-FP8` |
| Context | 262144 |
| GPUs | H200 NVL x4, tensor parallel 4 |
| Mode | non-thinking; Qwen3-Coder tool parser |
