<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/branding/denial-dark.svg">
    <img alt="Denial" src="assets/branding/denial.svg" width="768">
  </picture>
</h1>

<p align="center"><strong>A Flutter-native Wayland compositor.</strong></p>

Denial begins with a belief: origin does not have to dictate purpose.

Flutter was created to build application interfaces. Here, it is given a
different life. It owns the desktop scene itself: the shell, its motion, and
the composition of Wayland applications. Flutter is not an overlay placed on
top of another compositor. It is part of the compositor's foundation.

That is the architecture. It is also the meaning of the name.

## Why Denial

**Denial** is an English word. The name contains **Denia**, followed by one
last letter.

It is a quiet reference to Denia from *Wuthering Waves*. Her story never gives
a simple answer to what she originally was, and that uncertainty is important.
What is clear is that others treated her as an asset: something selected,
shaped, and assigned a purpose that was not her own. She was meant to remain a
vessel. Instead, by observing people and learning to live among them, she grew
a heart and gained the ability to choose what she would become.

The reference also carries the echo of the Russian farewell
*do svidaniya*—a goodbye that still leaves room for another meeting. Denia's
own goodbye is left unfinished. She promises to return, however many attempts
it takes, and saves the final words for the next time she and Rover meet.

Denial is that goodbye denied.

Flutter, too, is being used for something other than the purpose chosen for it.
It is not being abandoned at the boundary of an application window. It is
given a new role, a new life, and a new future.

The compositor is not named **Denia**. It is named **Denial**. One is the
inspiration; the other is an independent project with its own identity.

## Architecture follows meaning

Denial treats Flutter as the owner of one coherent desktop scene. Wayland
client buffers enter that scene as external textures alongside native shell
UI. Flutter renders a shared display atlas and KMS scans each monitor directly
from its own region of that buffer. There is no separate compositor pass that
redraws or blits the completed scene once per output. The Rust compositor
validates atlas dimensions and scanout constraints before allocation and
rejects unsupported layouts rather than entering an undefined presentation
path.

The result is not Flutter running *inside* a desktop. It is Flutter helping to
define what the desktop is.

The implementation is still in active development. Its compositor executable
is `deniald`, and its internal APIs, backend targets, and wire protocol all use
the Denial identity consistently.

Further technical notes:

- [PC development build](BUILDING.md)
- [Architecture notes](architecture.md)
- [Secure lock contract and migration status](SECURE_LOCK.md)
- [Open roadmap](ROADMAP.md)
- [Legacy Hyprland reference](LEGACY_HYPRLAND.md)

## Made through dialogue

Denial was conceived, directed, and tested by its human creator, and built in
continuous collaboration with OpenAI Codex. Its first implementation was
created without its creator writing the code by hand.

The human side gave the project its purpose, architectural judgment, taste,
real-hardware testing, and final decisions. Codex investigated, proposed,
implemented, measured, and refined the system through dialogue.

This is part of Denial's origin, not a disclaimer hidden in a footnote.
Authorship is more than typing. Denial exists because a person decided what
should exist, recognized when it was wrong, and kept directing the work until
it became real.

## Inspiration and independence

Denial is an independent, unofficial project. It is not affiliated with,
endorsed by, or sponsored by Kuro Games. It uses no *Wuthering Waves* artwork,
character likenesses, logos, audio, or other game assets as part of its name or
branding. The project name is the ordinary English word **Denial**; Denia's
story is acknowledged only as its literary inspiration.

The relevant story can be read in the community transcriptions of
[Denia's archives](https://wutheringwaves.fandom.com/wiki/Denia/Backstory) and
the quest
[*Beneath a Melting Night Sky*](https://wutheringwaves.fandom.com/wiki/Beneath_a_Melting_Night_Sky).
The Russian phrase
[*do svidaniya*](https://gramota.ru/poisk?dicts%5B0%5D=48&mode=slovari&query=%D0%B4%D0%BE+%D1%81%D0%B2%D0%B8%D0%B4%D0%B0%D0%BD%D0%B8%D1%8F&simple=0)
conventionally means goodbye or "until we meet again."
