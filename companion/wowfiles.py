"""Localisation des fichiers du jeu (lecture seule, sauf GuildChronicle_Press/Press.lua)."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

SV_NAME = "GuildChronicle.lua"


@dataclass
class WowPaths:
    root: Path                 # dossier _forever_ (ou _retail_)
    account: str | None = None

    @property
    def saved_variables(self) -> Path:
        account = self.account or self.find_account()
        return self.root / "WTF" / "Account" / account / "SavedVariables" / SV_NAME

    @property
    def logs(self) -> Path:
        return self.root / "Logs"

    @property
    def press(self) -> Path:
        return self.root / "Interface" / "AddOns" / "GuildChronicle_Press" / "Press.lua"

    def accounts_with_data(self) -> list[str]:
        base = self.root / "WTF" / "Account"
        if not base.is_dir():
            return []
        return sorted(p.name for p in base.iterdir() if (p / "SavedVariables" / SV_NAME).is_file())

    def find_account(self) -> str:
        found = self.accounts_with_data()
        if len(found) == 1:
            return found[0]
        if not found:
            raise FileNotFoundError(
                f"Aucun {SV_NAME} sous {self.root / 'WTF' / 'Account'} : lance le jeu avec l'addon puis fais /reload.")
        raise FileNotFoundError(f"Plusieurs comptes trouvés ({', '.join(found)}) : précise --account.")

    def combat_logs(self) -> list[Path]:
        if not self.logs.is_dir():
            return []
        return sorted(self.logs.glob("WoWCombatLog*.txt"), key=lambda p: p.stat().st_mtime)
