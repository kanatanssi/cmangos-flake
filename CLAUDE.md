# Example names

When docs, tests, fake data or examples need a player, character or account name, use one of these. The account name is the character name in lowercase. Prefer Perttupeikko and Hilmahaltia, and add the others when more are needed. Keep race, class and level as listed, and use the character notes for personas, memory or chat lines.

| Character | Race and class | Level | Faction | Pronouns | In-game gender |
|---|---|---|---|---|---|
| `Hilmahaltia` | Night Elf Hunter | 12 | Alliance | she/her | female |
| `Perttupeikko` | Troll Shaman | 20 | Horde | he/him | male |
| `Timotonttu` | Gnome Mage | 13 | Alliance | they/them | male |
| `Lasseluuranko` | Undead Rogue | 19 | Horde | he/him | male |
| `Mattimurloc` | Gnome Warrior | 3 | Alliance | he/him | male |

The game only knows male and female, so playerbots' `<bot gender>` / `<other gender>` always say one of those. Timotonttu goes by they/them, while the game and playerbots' prompt placeholders still say male. That makes Timotonttu the test case for pronouns the game can't express.

- **Hilmahaltia:** quiet and watchful, more at home in the woods than in town. Answers in few words, with a dry sense of humour. Never far from her nightsaber, Varjo, and protective of it.
- **Perttupeikko:** laid-back storyteller who talks to the spirits like old friends. Loves fishing and tall tales, and laughs at his own jokes before the punchline.
- **Timotonttu:** excitable tinkerer who treats every spell as an experiment, and half of them go slightly wrong. Hates the cold of Dun Morogh and complains about it constantly. Goes by they/them.
- **Lasseluuranko:** sardonic, with gallows humour. Polite in an unsettling way, trusts nobody, and has a habit of holding on to other people's coin purses.
- **Mattimurloc:** an earnest newbie who is sure he's a murloc, and looks like one. A saved transform aura (`character_aura`, spell 21751 "Perm. Illusion Skeleton" with a murloc display ID) keeps the murloc model across logins. Says "mrglglgl" a lot. Useful for testing a speaker whose look doesn't match the race the game reports (still Gnome).
