# CLAUDE.md, UlSource

WoW: Forever-addon som husker hvor materialene dine kommer fra. Søsken av UlRemedyForever (`~/prosjekter/UlRemedyForever/`), som er referansen for struktur, stil, testløkke og Forever-API; minnene der gjelder her også. Ingen delt kode.

## Kilder (Jonatans regel, 06.11.2026)

Bare Forever-kilder, aldri vanilla/vmangos, heller ikke som fallback. ForeverChanges (https://foreverchanges.pro) er ledestjernen og sjekkes først for alt. Deretter wago for Forever-builds, ForeverDB, og klienten selv (det addonet lærer i spill er en Forever-kilde). Mangler en Forever-kilde noe, sier addonet det. Se `~/CLAUDE.md`, avsnittet «WoW Forever-prosjektene».

**Navn (0.8.0, 07.11.2026):** Jonatan: «Jeg trenger ikke se drop-kilde når vi ikke vet hva mobben heter.» `NameData.lua` og `tools/build_names.py` er fjernet. Navn læres bare i spill (target ved loot, Names.lua etterpå); noder navngis etter urten/malmen de ga, fiskepunkt heter «Fishing pool» (loot innen 3 s etter Fishing-cast, flagget `fishing` på kilden og brukt av kartpinnene i stedet for den gamle FishingObjects-tabellen), kister forblir navnløse. `Store.ItemSources` lister bare navngitte kilder, så tooltip, vindu og `/us <id>` skjuler resten. Kopiert til spillmaskinen, ikke testet i spill.

**Nearby (0.8.0, 07.11.2026, Jonatan: «gjør det med NearbyData også»):** vmangos-posisjonene til trenere og selgere er fjernet, bare besøk læres (`UlSourceDB.nearby`), og `faction` på en lært post er borte, `seenBy` avgjør. `NearbyData.lua` har nå bare `reagents` (item → {klassetokens med mellomrom, navn}) og `ammo`, bygget av `tools/build_nearby.py` fra wago (SkillLine kategori 7 → SkillLineAbility → SpellReagents, ItemSparse BuyPrice > 0, Item klasse 6 sub 2/3), 22 reagenser og 34 ammo for build 70790. «Er dette en klassetrener»-sjekken (før: vanilla-liste `notClassTrainers`) leser nå NPC-ens egen tooltip-tittel via en skanne-tooltip (`UlSourceScanTooltip`, linje 2 og 3) og krever karakterens lokaliserte klassenavn i den. Ikke testet i spill; hvis tittelen er hemmelig på Forever læres ingen trenere, og da må en annen klientkilde finnes.

**Klassetrener-sjekk (0.8.1, 07.11.2026, Jonatan: «Vi burde jo har nok info nå, til å slippe å scanne treneren for info?»):** tooltip-skanningen fant ingen trenere (ingen feil, bare stille). Nå sammenlignes trenerens tjenester (`GetTrainerServiceInfo`) med navnene i karakterens egne klassefaner i spellboken (`C_SpellBook.GetNumSpellBookSkillLines`, `GetSpellBookSkillLineInfo`, `GetSpellBookItemName(slot, bank)`, guild- og offspec-linjer hoppes over); én felles spell er nok. Tooltip-tittelen er bare fallback. `UlSource.NearestTrainer()` skriver `lastTrainerCheck` som diagnose. Kopiert til spillmaskinen; trenerlæring ikke bekreftet i spill ennå.

## Status

`README.md` sin statuslinje er statusfasit for versjoner. 0.8.1 per 07.11.2026.
