#!/usr/bin/env python3
"""Small JSON-speaking bridge between DubLab and Bandit's local MLX runtime."""

from __future__ import annotations

import argparse
import json
import sys
import wave
from pathlib import Path

import numpy as np


CLEANING_STRENGTHS = {
    "gentle": np.float32(0.0),
    "balanced": np.float32(0.65),
    "strong": np.float32(1.0),
}


def report(stage: str, progress: float, detail: str) -> None:
    print(json.dumps({"stage": stage, "progress": progress, "detail": detail}), flush=True)


def read_pcm16_frames(source: wave.Wave_read, start: int, count: int) -> np.ndarray:
    source.setpos(start)
    frames = source.readframes(count)
    channels = source.getnchannels()
    audio = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    return audio.reshape(-1, channels).T


def pcm16_bytes(audio: np.ndarray) -> bytes:
    interleaved = np.clip(audio.T, -1.0, 1.0)
    return (interleaved * 32767.0).astype("<i2").tobytes()


def stem_with_shape(stems: dict[str, np.ndarray], name: str, shape: tuple[int, int]) -> np.ndarray:
    if name not in stems:
        raise ValueError(f"Bandit did not produce its {name} stem")
    stem = np.asarray(stems[name], dtype=np.float32)
    if stem.shape != shape:
        raise ValueError(
            f"Bandit's {name} stem shape {stem.shape} does not match the movie mix {shape}"
        )
    return np.nan_to_num(stem, nan=0.0, posinf=1.0, neginf=-1.0)


def build_complementary_stems(
    audio: np.ndarray,
    stems: dict[str, np.ndarray],
    cleaning_preset: str,
) -> tuple[np.ndarray, np.ndarray]:
    """Create stems that reconstruct the source while honoring quality mode.

    Bandit's speech estimate alone is deliberately conservative. Subtracting
    only that estimate leaves every missed syllable in the background. Bandit
    also predicts music and effects directly; stronger modes increasingly use
    those dialogue-free estimates. Dialogue is then defined as the exact
    complement so normal playback still reconstructs the source continuously.
    """
    try:
        direct_strength = CLEANING_STRENGTHS[cleaning_preset]
    except KeyError as error:
        raise ValueError(f"Unknown dialogue cleaning preset: {cleaning_preset}") from error

    shape = audio.shape
    speech = stem_with_shape(stems, "speech", shape)
    music = stem_with_shape(stems, "music", shape)
    effects = stem_with_shape(stems, "effects", shape)

    # Keep the conservative residual representable before blending it with
    # Bandit's direct dialogue-free prediction.
    minimum_dialogue = np.maximum(-1.0, audio - 1.0)
    maximum_dialogue = np.minimum(1.0, audio + 1.0)
    speech = np.clip(speech, minimum_dialogue, maximum_dialogue)
    residual_background = audio - speech
    direct_background = music + effects
    background = (
        residual_background * (np.float32(1.0) - direct_strength)
        + direct_background * direct_strength
    )

    # Both stems are stored as PCM16. Constrain the background to the range in
    # which it and its exact complement remain representable without clipping.
    minimum_background = np.maximum(-1.0, audio - 1.0)
    maximum_background = np.minimum(1.0, audio + 1.0)
    background = np.clip(background, minimum_background, maximum_background)
    dialogue = audio - background
    return dialogue.astype(np.float32), background.astype(np.float32)


def load_session(weights: Path):
    from bandit_infer import BanditSession

    report("model", 0.05, "Checking the Bandit v2 model")
    session = BanditSession("v2-multi", backend="mlx", weights_dir=weights)
    session.load()
    report("model", 1.0, "Bandit v2 is ready")
    return session


def separate_streaming(
    session,
    input_path: Path,
    background_path: Path,
    dialogue_path: Path | None,
    dialogue_input_path: Path | None,
    cleaning_preset: str,
) -> None:
    """Separate long movies in bounded-memory overlapping regions.

    Dialogue and background use complementary estimates and identical overlap
    windows, so their sum remains the source mix across every internal boundary.
    """
    chunk_seconds = 180
    overlap_seconds = 2
    with wave.open(str(input_path), "rb") as source:
        if source.getsampwidth() != 2:
            raise ValueError("DubLab's Bandit bridge requires 16-bit PCM input")
        sample_rate = source.getframerate()
        output_channels = source.getnchannels()
        total_frames = source.getnframes()
        if total_frames <= 0:
            raise ValueError("The extracted movie audio is empty")
        reference = wave.open(str(dialogue_input_path), "rb") if dialogue_input_path else None
        try:
            if reference is not None:
                if reference.getsampwidth() != 2 or reference.getframerate() != sample_rate:
                    raise ValueError("The center reference and movie mix must share one PCM format")
                if reference.getnchannels() != 1:
                    raise ValueError("The surround center reference must be mono")
                if reference.getnframes() != total_frames:
                    raise ValueError("The center reference and movie mix must have equal duration")

            background_path.parent.mkdir(parents=True, exist_ok=True)
            if dialogue_path is not None:
                dialogue_path.parent.mkdir(parents=True, exist_ok=True)
            with wave.open(str(background_path), "wb") as background_writer:
                background_writer.setnchannels(output_channels)
                background_writer.setsampwidth(2)
                background_writer.setframerate(sample_rate)
                dialogue_writer = wave.open(str(dialogue_path), "wb") if dialogue_path else None
                try:
                    if dialogue_writer is not None:
                        dialogue_writer.setnchannels(output_channels)
                        dialogue_writer.setsampwidth(2)
                        dialogue_writer.setframerate(sample_rate)

                    chunk_frames = chunk_seconds * sample_rate
                    overlap_frames = overlap_seconds * sample_rate
                    step_frames = chunk_frames - overlap_frames
                    start = 0
                    pending_dialogue = None
                    pending_background = None

                    while start < total_frames:
                        count = min(chunk_frames, total_frames - start)
                        audio = read_pcm16_frames(source, start, count)
                        if audio.shape[1] != count:
                            raise ValueError(
                                "The extracted movie audio has an invalid duration header. "
                                "Prepare the movie audio again with this version of DubLab."
                            )
                        if reference is not None:
                            reference_audio = read_pcm16_frames(reference, start, count)
                        else:
                            reference_audio = None
                        if reference_audio is not None and reference_audio.shape[1] != count:
                            raise ValueError(
                                "The extracted center reference has an invalid duration header. "
                                "Prepare the movie audio again with this version of DubLab."
                            )
                        # Always infer from the complete movie mix. The former
                        # center-only path discarded stereo context and caused a
                        # major dialogue-removal regression on surround sources.
                        stems = session.infer(audio, sample_rate=sample_rate)
                        dialogue, background = build_complementary_stems(
                            audio,
                            stems,
                            cleaning_preset,
                        )

                        is_final = start + count >= total_frames
                        if pending_dialogue is None:
                            if is_final:
                                dialogue_writer and dialogue_writer.writeframes(pcm16_bytes(dialogue))
                                background_writer.writeframes(pcm16_bytes(background))
                            else:
                                split = max(dialogue.shape[1] - overlap_frames, 0)
                                dialogue_writer and dialogue_writer.writeframes(pcm16_bytes(dialogue[:, :split]))
                                background_writer.writeframes(pcm16_bytes(background[:, :split]))
                                pending_dialogue = dialogue[:, split:]
                                pending_background = background[:, split:]
                        else:
                            blend_count = min(
                                pending_dialogue.shape[1],
                                dialogue.shape[1],
                                overlap_frames,
                            )
                            fade_in = np.linspace(0, 1, blend_count, dtype=np.float32)[None, :]
                            blended_dialogue = (
                                pending_dialogue[:, :blend_count] * (1 - fade_in)
                                + dialogue[:, :blend_count] * fade_in
                            )
                            blended_background = (
                                pending_background[:, :blend_count] * (1 - fade_in)
                                + background[:, :blend_count] * fade_in
                            )
                            dialogue_writer and dialogue_writer.writeframes(pcm16_bytes(blended_dialogue))
                            background_writer.writeframes(pcm16_bytes(blended_background))

                            remaining_dialogue = dialogue[:, blend_count:]
                            remaining_background = background[:, blend_count:]
                            if is_final:
                                dialogue_writer and dialogue_writer.writeframes(pcm16_bytes(remaining_dialogue))
                                background_writer.writeframes(pcm16_bytes(remaining_background))
                            else:
                                split = max(remaining_dialogue.shape[1] - overlap_frames, 0)
                                dialogue_writer and dialogue_writer.writeframes(
                                    pcm16_bytes(remaining_dialogue[:, :split])
                                )
                                background_writer.writeframes(
                                    pcm16_bytes(remaining_background[:, :split])
                                )
                                pending_dialogue = remaining_dialogue[:, split:]
                                pending_background = remaining_background[:, split:]

                        completed = min(start + count, total_frames)
                        report(
                            "separation",
                            0.1 + 0.78 * completed / max(total_frames, 1),
                            f"Separating movie audio — {completed / sample_rate / 60:.1f} of {total_frames / sample_rate / 60:.1f} min",
                        )
                        if is_final:
                            break
                        start += step_frames
                finally:
                    if dialogue_writer is not None:
                        dialogue_writer.close()
        finally:
            if reference is not None:
                reference.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--input", type=Path)
    parser.add_argument("--background", type=Path)
    parser.add_argument("--dialogue", type=Path)
    parser.add_argument("--dialogue-input", type=Path)
    parser.add_argument(
        "--cleaning-preset",
        choices=tuple(CLEANING_STRENGTHS),
        default="balanced",
    )
    args = parser.parse_args()

    session = load_session(args.weights)
    if args.prepare:
        return 0
    if args.input is None or args.background is None:
        parser.error("--input and --background are required for separation")

    report("audio", 0.0, "Opening the continuous movie mix")
    report("separation", 0.1, "Separating continuous dialogue, music, and effects")
    separate_streaming(
        session=session,
        input_path=args.input,
        background_path=args.background,
        dialogue_path=args.dialogue,
        dialogue_input_path=args.dialogue_input,
        cleaning_preset=args.cleaning_preset,
    )
    report("output", 0.9, "Finalizing continuous movie stems")
    report("complete", 1.0, "Clean background is ready")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr, flush=True)
        raise
