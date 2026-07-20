#requires -Version 7.0
<#
.SYNOPSIS
  Set up the OPTIONAL local image-generation stack (ComfyUI + FLUX) on an Atlas host that has an
  NVIDIA GPU. This is the GPU opt-in for the `image_generation` plugin - Atlas runs cloud-first and
  does NOT need this; only run it if you want $0 on-box image/wallpaper/3D generation.

.DESCRIPTION
  Installs into ${DataRoot}\image-gen\ComfyUI (the path the Atlas Agent's ComfyUiHandler expects):
    1. git clone ComfyUI + create a Python venv + install requirements (+ CUDA torch).
    2. Download the FLUX models into the exact dirs the Atlas workflow references:
         models/unet/flux1-schnell.safetensors        (open - FLUX.1-schnell, Apache-2.0)
         models/clip/t5xxl_fp8_e4m3fn.safetensors      (open - comfyanonymous/flux_text_encoders)
         models/clip/clip_l.safetensors                (open)
         models/vae/ae.safetensors                     (open)
       These four make the default "quick" tier (FLUX.1-schnell) work out of the box.
    3. flux1-dev (the higher-quality "quality"/"high" tiers) is HF-GATED: you must accept its license
       at https://huggingface.co/black-forest-labs/FLUX.1-dev and provide an HF token (-HfToken or the
       HF_TOKEN env var). Without it, this script skips dev and image-gen still works on schnell.

  The Agent auto-starts ComfyUI on demand (GET /system_stats -> launch main.py --port 8188), so you do
  NOT run ComfyUI yourself - just install it here and enable the image_generation plugin.

  NOTE: this pulls ~20-25 GB of model weights + a multi-GB Python/torch env. Requires: git, Python 3.11+,
  an NVIDIA GPU + recent driver. Optional 3D (TripoSR/TripoSG) is a separate add-on (-Include3D).

.PARAMETER DataRoot   Atlas data root (default C:\Atlas). ComfyUI lands in <DataRoot>\image-gen\ComfyUI.
.PARAMETER HfToken    HuggingFace token (for the gated flux1-dev). Or set $env:HF_TOKEN. Optional.
.PARAMETER Include3D  Also clone TripoSR + TripoSG for image_to_3d (large first-run weight downloads).
.PARAMETER SkipModels Install ComfyUI only; download models yourself later.

.EXAMPLE
  pwsh ./scripts/setup-image-gen.ps1                       # schnell only (open models)
  pwsh ./scripts/setup-image-gen.ps1 -HfToken hf_xxx       # + gated flux1-dev
#>
[CmdletBinding()]
param(
    [string]$DataRoot  = 'C:\Atlas',
    [string]$HfToken   = $env:HF_TOKEN,
    [switch]$Include3D,
    [switch]$IncludeVideo,
    [switch]$IncludeVideo13B,   # force-fetch the 13B distilled model regardless of detected VRAM
    [switch]$IncludeLtx2,       # force-fetch the LTX-2.3 "cinematic" set (~39GB) regardless of VRAM
    [switch]$SkipModels
)
$ErrorActionPreference = 'Stop'
function Step($m){ Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "    OK  $m" -ForegroundColor Green }
function Warn2($m){ Write-Host "    !   $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "    X   $m" -ForegroundColor Red; exit 1 }

# --- Prereqs -----------------------------------------------------------------
Step 'Checking prerequisites'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git not found. Install Git and re-run.' }
$py = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction SilentlyContinue)
if (-not $py) { Die 'Python 3.11+ not found. Install it and re-run.' }
$hasGpu = $false
try { if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { nvidia-smi *> $null; $hasGpu = ($LASTEXITCODE -eq 0) } } catch {}
if (-not $hasGpu) { Warn2 'No NVIDIA GPU detected. Image-gen needs a GPU - install will proceed but generation will be very slow/unusable on CPU.' }

$imgRoot  = Join-Path $DataRoot 'image-gen'
$comfyDir = Join-Path $imgRoot 'ComfyUI'
New-Item -ItemType Directory -Force $imgRoot | Out-Null

# --- ComfyUI + venv ----------------------------------------------------------
if (Test-Path (Join-Path $comfyDir 'main.py')) {
    Ok "ComfyUI already present at $comfyDir"
} else {
    Step "Cloning ComfyUI into $comfyDir"
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git $comfyDir
    if ($LASTEXITCODE -ne 0) { Die 'ComfyUI clone failed.' }
}
$venvPy = Join-Path $comfyDir '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPy)) {
    Step 'Creating Python venv + installing requirements (torch CUDA - several GB, a while)'
    & $py.Source -m venv (Join-Path $comfyDir '.venv')
    & $venvPy -m pip install --upgrade pip
    & $venvPy -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
    & $venvPy -m pip install -r (Join-Path $comfyDir 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { Warn2 'pip install reported an error - check the output; you may need a matching CUDA wheel.' }
}
Ok 'ComfyUI + venv ready'

# --- Models ------------------------------------------------------------------
if ($SkipModels) { Warn2 'Skipping model downloads (-SkipModels). Image-gen will not work until models are in place.'; exit 0 }

function Get-Model($url, $destDir, $name, [bool]$gated=$false) {
    $dir = Join-Path $comfyDir $destDir
    New-Item -ItemType Directory -Force $dir | Out-Null
    $dest = Join-Path $dir $name
    if (Test-Path $dest) { Ok "$name already present"; return }
    $headers = @{}
    if ($gated) { if (-not $HfToken) { Warn2 "$name is GATED - skipping (accept the license + pass -HfToken to fetch it)."; return }; $headers['Authorization'] = "Bearer $HfToken" }
    Step "Downloading $name (this is large)"
    try { Invoke-WebRequest -Uri $url -OutFile $dest -Headers $headers -TimeoutSec 7200 } catch { Warn2 "failed to download $name : $($_.Exception.Message)"; Remove-Item $dest -ErrorAction SilentlyContinue; return }
    Ok "$name downloaded"
}

Step 'Downloading FLUX models to the dirs the Atlas workflow references'
# Open models (schnell tier works with just these) — Comfy-Org repackaged single-files.
Get-Model 'https://huggingface.co/Comfy-Org/flux1-schnell/resolve/main/flux1-schnell-fp8.safetensors' 'models\unet' 'flux1-schnell.safetensors'
Get-Model 'https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors' 'models\clip' 't5xxl_fp8_e4m3fn.safetensors'
Get-Model 'https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors' 'models\clip' 'clip_l.safetensors'
Get-Model 'https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors' 'models\vae' 'ae.safetensors'
# 4x ESRGAN for the render-small-upscale-big path: targets over ~2.5 MP render at half
# resolution then model-upscale to exact size (sharper + ~4x faster than native 4K FLUX).
Get-Model 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth' 'models\upscale_models' 'RealESRGAN_x4plus.pth'
# Gated (higher-quality "quality"/"high" tiers) — needs HF license + token.
Get-Model 'https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors' 'models\unet' 'flux1-dev.safetensors' $true

# Video Studio (LTX-Video) — the checkpoint goes in models/checkpoints/; it reuses the T5 encoder above.
# Text-to-video, image-to-video, and .webm output all use NATIVE ComfyUI LTXV nodes (no custom nodes).
if ($IncludeVideo) {
    Step 'Video Studio (LTX-Video) - detecting GPU + fetching the models that fit'
    # HARDWARE-AWARE: fetch the video models that suit the detected VRAM. Every threshold is overridable with
    # -IncludeVideo13B / -IncludeLtx2 (grab a bigger model anyway - you may upgrade the GPU, or be happy to wait
    # through heavy shared-RAM offload). The web Video Studio still lets you PICK any tier that's installed.
    $vramMb = 0
    try { $vramMb = [int]((& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)) } catch {}
    if ($vramMb -gt 0) { Ok "GPU VRAM detected: ${vramMb} MB" } else { Warn2 'no GPU VRAM detected - fetching only the small 2B model' }
    $defaultTier = 'quick'

    # Draft tier = 2B 0.9.8 DISTILLED (fp8, ~4GB) - ALWAYS. Universal (fits any GPU, even alongside a game).
    # The proper LTX sampling pipeline (ModelSamplingLTXV + LTXVScheduler + SamplerCustom) makes it lifelike.
    Get-Model 'https://huggingface.co/Lightricks/LTX-Video/resolve/main/ltxv-2b-0.9.8-distilled-fp8.safetensors' 'models\checkpoints' 'ltxv-2b-0.9.8-distilled-fp8.safetensors'

    # Quality tier = 13B 0.9.8 distilled (fp8, ~17GB) - runs on a ~16GB GPU when it's otherwise free (~80s).
    # Auto on >=14GB VRAM, or force with -IncludeVideo13B.
    if ($vramMb -ge 14000 -or $IncludeVideo13B) {
        Get-Model 'https://huggingface.co/Lightricks/LTX-Video/resolve/main/ltxv-13b-0.9.8-distilled-fp8.safetensors' 'models\checkpoints' 'ltxv-13b-0.9.8-distilled-fp8.safetensors'
        $defaultTier = 'quality'
    } else { Warn2 '13B (quality tier) skipped - needs ~14GB+ VRAM. Force with -IncludeVideo13B.' }

    # Cinematic tier = LTX-2.3 (gen-2, 22B nvfp4 - the ltx.io-class lifelike model) + Gemma-3-12B encoder +
    # distilled LoRA + two spatial upscalers (~39GB), plus the Lightricks ComfyUI-LTXVideo node pack. Needs a
    # ~16GB Blackwell GPU (native FP4). Auto on >=15GB, or force with -IncludeLtx2.
    if ($vramMb -ge 15000 -or $IncludeLtx2) {
        Step 'Installing the ComfyUI-LTXVideo node pack + the LTX-2.3 set (~39GB)'
        $ltxNode = Join-Path $comfyDir 'custom_nodes\ComfyUI-LTXVideo'
        if (-not (Test-Path $ltxNode)) {
            git clone --depth 1 https://github.com/Lightricks/ComfyUI-LTXVideo.git $ltxNode
            if (Test-Path (Join-Path $ltxNode 'requirements.txt')) { & $venvPy -m pip install -r (Join-Path $ltxNode 'requirements.txt') }
        }
        Get-Model 'https://huggingface.co/Lightricks/LTX-2.3-nvfp4/resolve/main/ltx-2.3-22b-dev-nvfp4.safetensors' 'models\checkpoints' 'ltx-2.3-22b-dev-nvfp4.safetensors'
        Get-Model 'https://huggingface.co/GitMylo/LTX-2-comfy_gemma_fp8_e4m3fn/resolve/main/gemma_3_12B_it_fp8_e4m3fn.safetensors' 'models\text_encoders' 'comfy_gemma_3_12B_it.safetensors'
        Get-Model 'https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-distilled-lora-384-1.1.safetensors' 'models\loras\ltxv\ltx2' 'ltx-2.3-22b-distilled-lora-384-1.1.safetensors'
        Get-Model 'https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.1.safetensors' 'models\latent_upscale_models' 'ltx-2.3-spatial-upscaler-x2-1.1.safetensors'
        Get-Model 'https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors' 'models\latent_upscale_models' 'ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors'
        $defaultTier = 'cinematic'
    } else { Warn2 'LTX-2.3 (cinematic tier) skipped - needs ~16GB VRAM. Force with -IncludeLtx2 (slow via shared-RAM offload on smaller cards, but it works).' }

    Write-Host ""
    Write-Host "  Recommended default video tier for this GPU: $defaultTier" -ForegroundColor Green
    Write-Host "  Set it as the Video Studio default with:  IMAGEGEN_VIDEO_DEFAULT_QUALITY=$defaultTier in .env" -ForegroundColor Gray
    Write-Host "  (Every INSTALLED tier stays choosable in the UI - this only sets which is pre-selected.)" -ForegroundColor Gray
    # OPTIONAL: real .mp4 output (set image_gen:video_format=mp4) needs the VideoHelperSuite custom node +
    # ffmpeg. The default output is .webm (native SaveWEBM, no extra deps) — skip this if webm is fine.
    $vhs = Join-Path $comfyDir 'custom_nodes\ComfyUI-VideoHelperSuite'
    if (-not (Test-Path $vhs)) {
        Step 'Installing ComfyUI-VideoHelperSuite (optional .mp4 output)'
        git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git $vhs
        if (Test-Path (Join-Path $vhs 'requirements.txt')) { & $venvPy -m pip install -r (Join-Path $vhs 'requirements.txt') }
        Warn2 'mp4 output also needs ffmpeg on PATH. Default video_format is webm (native) - no ffmpeg needed.'
    }
}

# --- Optional 3D -------------------------------------------------------------
if ($Include3D) {
    Step 'Cloning TripoSR (fast) + TripoSG (hi-fi) for image_to_3d'
    $sr = Join-Path $imgRoot 'TripoSR_v1'; $sg = Join-Path $imgRoot 'TripoSG'
    if (-not (Test-Path $sr)) { git clone --depth 1 https://github.com/VAST-AI-Research/TripoSR.git $sr }
    if (-not (Test-Path $sg)) { git clone --depth 1 https://github.com/VAST-AI-Research/TripoSG.git $sg }
    Warn2 'TripoSR/SG need their own venv + requirements; weights download on first use. See each repo README.'
}

Write-Host ''
Write-Host 'Image-gen setup complete.' -ForegroundColor White
Write-Host '  - Enable the "image_generation" plugin in Atlas (Plugin Store).' -ForegroundColor White
Write-Host '  - The Atlas Agent auto-starts ComfyUI on the first generation.' -ForegroundColor White
if (-not $HfToken) { Write-Host '  - Only FLUX.1-schnell (the "quick" tier) is installed. For "quality"/"high" (FLUX.1-dev), accept the license at huggingface.co/black-forest-labs/FLUX.1-dev and re-run with -HfToken.' -ForegroundColor Gray }
