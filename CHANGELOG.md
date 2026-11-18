# Changelog

All notable changes to this project will be documented in this file.

## [1.0.1] - 2026-11-18

### Changed
- Picks up game-common 1.17.0 (a board redraw fix used by chess, binairo and
  tatami; no change in this game).

## [1.0.0] - 2026-11-10

### Added
- First release: a hidden-movement duel for two players with a reader each.
  Both readers build the same sea from the game code; each player hides a
  submarine, announces only the direction of each move, the cell of each
  torpedo and the quarter where they surface. Each reader checks its own
  submarine (trail, range, damage) and shades every cell where the enemy can
  still be, from what the opponent announced.
- Small sea 8×8 or open sea 10×10, torpedo with a 3-move recharge and
  splash damage, Undo, shading on or off, auto-save.
