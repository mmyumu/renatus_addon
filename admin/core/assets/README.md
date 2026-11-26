# Assets of the gazette's printed pages (`src/typeset.rs`, `src/print.rs`)

Embedded in the app (`include_bytes!`), used to draw the gazette as images for Discord.

- `fonts/UnifrakturMaguntia-Book.ttf`: masthead. SIL Open Font License 1.1, `fonts/OFL-UnifrakturMaguntia.txt`.
- `fonts/IMFeENrm28P.ttf`, `fonts/IMFeENit28P.ttf` (IM Fell English): headlines, quotes. SIL OFL 1.1, `fonts/OFL-IMFellEnglish.txt`.
- `fonts/CrimsonText-*.ttf`: body text. SIL OFL 1.1, `fonts/OFL-CrimsonText.txt`.
- `hyph-fr.pat.txt`: French hyphenation patterns (hyph-utf8, `hyph-fr.tex`), MIT license,
  © 1994-2002 Daniel Flipo, Bernard Gaulle, 2016 Arthur Reutenauer.
- `paper.png`: the addon's paper texture (`Renatus/Media/paper.tga`, `tools/make_media.py`).

All fonts come from github.com/google/fonts (`ofl/`).
