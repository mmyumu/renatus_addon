import argparse
import math
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RESOURCES = ROOT / "Resources"
DEFAULT_INPUT = RESOURCES
DEFAULT_OUTPUT = RESOURCES / "boosted"


def check_ffmpeg():
    if shutil.which("ffmpeg") is None:
        raise SystemExit(
            "ffmpeg n'est pas installé ou n'est pas dans le PATH. Installe ffmpeg et relance ce script."
        )


def resolve_path(path: str | Path) -> Path:
    resolved = Path(path)
    if not resolved.is_absolute():
        resolved = ROOT / resolved
    return resolved


def build_filter(preset: str, loudness: float, lra: float, tp: float, gain: float) -> str:
    filters = []
    if preset == "combat":
        filters.extend(
            [
                "highpass=f=220",
                "lowpass=f=7800",
                "equalizer=f=2500:t=q:w=0.9:g=6",
                "equalizer=f=4300:t=q:w=1.1:g=4",
                "compand=attacks=0.005:decays=0.08:points=-80/-80|-50/-35|-35/-22|-20/-10|-8/-4|0/-1.5:soft-knee=8:gain=7:volume=-5",
                "aresample=async=1:first_pts=0",
            ]
        )
    else:
        filters.append(f"loudnorm=I={loudness}:LRA={lra}:TP={tp}")
    if gain != 0.0:
        filters.append(f"volume={gain}dB")
    limiter_limit = min(max(math.pow(10.0, tp / 20.0), 0.0625), 1.0)
    filters.append(f"alimiter=limit={limiter_limit:.6f}")
    return ",".join(filters)


def display_path(path: Path) -> Path:
    try:
        return path.relative_to(ROOT)
    except ValueError:
        return path


def process_file(input_path: Path, output_path: Path, audio_filter: str) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "warning",
        "-y",
        "-i",
        str(input_path),
        "-af",
        audio_filter,
        "-c:a",
        "libvorbis",
        "-qscale:a",
        "5",
        str(output_path),
    ]
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"Erreur ffmpeg sur {input_path.name}: code {exc.returncode}") from exc
    print(f"Traité: {input_path.name} -> {display_path(output_path)}")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Normalize and boost all .ogg files in Resources using ffmpeg."
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Écrase les fichiers originaux au lieu de créer un dossier boosted.",
    )
    parser.add_argument(
        "--output-dir",
        default=DEFAULT_OUTPUT,
        help="Dossier de sortie pour les fichiers traités.",
    )
    parser.add_argument(
        "--input-dir",
        default=DEFAULT_INPUT,
        help="Dossier contenant les fichiers .ogg source.",
    )
    parser.add_argument(
        "--preset",
        choices=("normal", "combat"),
        default="normal",
        help="Preset audio: normal booste le volume, combat privilégie l'intelligibilité en raid/donjon.",
    )
    parser.add_argument(
        "--loudness",
        type=float,
        default=None,
        help="Niveau LUFS cible pour la normalisation.",
    )
    parser.add_argument(
        "--lra",
        type=float,
        default=None,
        help="Plage dynamique cible LRA.",
    )
    parser.add_argument(
        "--tp",
        type=float,
        default=None,
        help="True peak target en dBTP.",
    )
    parser.add_argument(
        "--gain",
        type=float,
        default=None,
        help="Gain supplémentaire en dB à appliquer après la normalisation.",
    )
    return parser.parse_args()


def apply_preset_defaults(args) -> None:
    if args.preset == "combat":
        args.loudness = -13.0 if args.loudness is None else args.loudness
        args.lra = 7.0 if args.lra is None else args.lra
        args.tp = -1.0 if args.tp is None else args.tp
        args.gain = 0.0 if args.gain is None else args.gain
    else:
        args.loudness = -16.0 if args.loudness is None else args.loudness
        args.lra = 11.0 if args.lra is None else args.lra
        args.tp = -1.5 if args.tp is None else args.tp
        args.gain = 4.0 if args.gain is None else args.gain


def main():
    args = parse_args()
    apply_preset_defaults(args)
    check_ffmpeg()

    input_dir = resolve_path(args.input_dir)
    if not input_dir.exists() or not input_dir.is_dir():
        raise SystemExit(f"Dossier introuvable: {input_dir}")

    ogg_files = sorted(input_dir.glob("*.ogg"))
    if not ogg_files:
        raise SystemExit(f"Aucun fichier .ogg trouvé dans {input_dir}.")

    audio_filter = build_filter(args.preset, args.loudness, args.lra, args.tp, args.gain)
    output_dir = resolve_path(args.output_dir)

    if args.overwrite:
        temp_dir = ROOT / "boosted_temp"
        temp_dir.mkdir(parents=True, exist_ok=True)
        for ogg_file in ogg_files:
            temp_output = temp_dir / ogg_file.name
            process_file(ogg_file, temp_output, audio_filter)
        for temp_file in temp_dir.glob("*.ogg"):
            original_file = RESOURCES / temp_file.name
            shutil.move(str(temp_file), str(original_file))
        shutil.rmtree(temp_dir)
        print(f"Traitement terminé. Fichiers originaux écrasés.")
    else:
        output_dir.mkdir(parents=True, exist_ok=True)
        for ogg_file in ogg_files:
            output_file = output_dir / ogg_file.name
            process_file(ogg_file, output_file, audio_filter)
        print(f"Traitement terminé. Fichiers boostés dans: {output_dir}")
        print("Note: l'addon joue Resources/*.ogg. Utilise --overwrite pour remplacer les fichiers joués.")


if __name__ == "__main__":
    main()
