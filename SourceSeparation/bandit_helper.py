#!/usr/bin/env python3
"""Small JSON-speaking bridge between DubLab and Bandit's local MLX runtime."""

from __future__ import annotations

import argparse
import json
import sys
import wave
from pathlib import Path

import numpy as np


def report(stage: str, progress: float, detail: str) -> None:
    print(json.dumps({"stage": stage, "progress": progress, "detail": detail}), flush=True)


def read_pcm16(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        if source.getsampwidth() != 2:
            raise ValueError("DubLab's Bandit bridge requires 16-bit PCM input")
        sample_rate = source.getframerate()
        channels = source.getnchannels()
        frames = source.readframes(source.getnframes())
    audio = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    return audio.reshape(-1, channels).T, sample_rate


def write_pcm16(path: Path, audio: np.ndarray, sample_rate: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    interleaved = np.clip(audio.T, -1.0, 1.0)
    samples = (interleaved * 32767.0).astype("<i2").tobytes()
    with wave.open(str(path), "wb") as destination:
        destination.setnchannels(audio.shape[0])
        destination.setsampwidth(2)
        destination.setframerate(sample_rate)
        destination.writeframes(samples)


def cancel_center_bleed(audio: np.ndarray, strength: float) -> np.ndarray:
    """Create stereo background while cancelling center duplicated into surrounds."""
    if audio.shape[0] < 6:
        return audio

    center = audio[2]
    denominator = float(np.dot(center, center)) + 1e-9

    def residual(channel: int, maximum: float) -> np.ndarray:
        coefficient = float(np.clip(np.dot(audio[channel], center) / denominator, 0.0, maximum))
        return audio[channel] - coefficient * center * strength

    front_left = residual(0, 0.8)
    front_right = residual(1, 0.8)
    left_surrounds = [residual(4, 0.5)]
    right_surrounds = [residual(5, 0.5)]
    if audio.shape[0] >= 8:
        left_surrounds.append(residual(6, 0.5))
        right_surrounds.append(residual(7, 0.5))

    left_surround = np.mean(left_surrounds, axis=0)
    right_surround = np.mean(right_surrounds, axis=0)
    lfe = audio[3]
    cancelled = np.stack([
        0.707 * front_left + 0.5 * left_surround + 0.25 * lfe,
        0.707 * front_right + 0.5 * right_surround + 0.25 * lfe,
    ])

    # Restore the energy of a center-free spatial downmix without undoing the
    # cancellation. The clamp prevents quiet passages from amplifying noise.
    reference = np.stack([
        0.707 * audio[0] + 0.5 * np.mean(audio[[4] + ([6] if audio.shape[0] >= 8 else [])], axis=0) + 0.25 * lfe,
        0.707 * audio[1] + 0.5 * np.mean(audio[[5] + ([7] if audio.shape[0] >= 8 else [])], axis=0) + 0.25 * lfe,
    ])
    target_rms = float(np.sqrt(np.mean(reference * reference)))
    current_rms = float(np.sqrt(np.mean(cancelled * cancelled))) + 1e-9
    return cancelled * float(np.clip(target_rms / current_rms, 0.8, 1.5))


def load_session(weights: Path):
    from bandit_infer import BanditSession

    report("model", 0.05, "Checking the Bandit v2 model")
    session = BanditSession("v2-multi", backend="mlx", weights_dir=weights)
    session.load()
    report("model", 1.0, "Bandit v2 is ready")
    return session


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--input", type=Path)
    parser.add_argument("--background", type=Path)
    parser.add_argument("--dialogue-reduction", type=float, default=1.0)
    parser.add_argument("--center-cancel", action="store_true")
    parser.add_argument("--center-cancel-strength", type=float, default=1.0)
    args = parser.parse_args()

    session = load_session(args.weights)
    if args.prepare:
        return 0
    if args.input is None or args.background is None:
        parser.error("--input and --background are required for separation")

    report("audio", 0.0, "Reading the movie audio")
    audio, sample_rate = read_pcm16(args.input)
    if args.center_cancel:
        report("channels", 0.05, "Cancelling duplicated center-channel dialogue")
        audio = cancel_center_bleed(audio, float(np.clip(args.center_cancel_strength, 0.0, 1.0)))
    report("separation", 0.1, "Separating dialogue, music, and effects")
    stems = session.infer(audio, sample_rate=sample_rate)
    # A value above 1 compensates when the separator underestimates dialogue.
    # The UI deliberately keeps this conservative to avoid metallic artifacts.
    reduction = min(max(args.dialogue_reduction, 1.0), 2.0)
    background = audio - reduction * stems["speech"]
    report("output", 0.9, "Writing the clean background")
    write_pcm16(args.background, background, sample_rate)
    report("complete", 1.0, "Clean background is ready")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr, flush=True)
        raise
