#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
==============================================================================
Nameless Deity - Guardião da Progressão Linear & Objetivos (Terraria / Calamity)
==============================================================================
- Rastreia a linha do tempo linear de Bosses (Vanilla + Calamity + Addons) com
  detalhes de Invocação e Bioma.
- Lê automaticamente flags de bosses derrotados do arquivo .twld (NBT GZip) e
  monitora o server.log / console em tempo real.
- Mantém Marcos Pré-definidos da Campanha (Shimmer, Abismo, Labs de Draedon,
  Eventos) + Metas Customizadas criadas pelos jogadores.
- Permite consultar e marcar/desmarcar objetivos tanto pelo Chat do Jogo
  (!progresso, !proximo, !bosses, !objetivos, !marcar, !desmarcar, !meta)
  quanto pelo Discord (Bot "Nameless Deity" com Slash Commands / Comandos de
  Prefixo + Webhook automático).
==============================================================================
"""

import base64
import datetime
import difflib
import gzip
import io
import json
import os
import re
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

BOT_NAME = "Nameless Deity"
COLOR_COSMIC_GOLD = 0xF1C40F
COLOR_COSMIC_PURPLE = 0x9B59B6
COLOR_COSMIC_CYAN = 0x00E5FF
COLOR_COSMIC_GREEN = 0x2ECC71

# ==============================================================================
# 1. CATÁLOGO LINEAR DE BOSSES (VANILLA + CALAMITY + ADDONS)
# ==============================================================================
# Campos:
#   id: identificador único curto
#   name: nome oficial em Inglês (para busca fácil no Recipe Browser / Wiki)
#   mod: "Vanilla" | "CalamityMod" | "CatalystMod" | "CalamityHunt" | "NoxusBoss"
#   phase: "pre_hardmode" | "hardmode" | "post_moonlord"
#   summon: item ou método de invocação
#   biome: bioma e condição (horário/clima) em Português
#   twld_keys: chaves booleanas/listas salvas no .twld (tModLoader / Calamity / BossChecklist)
#   log_aliases: nomes alternativos que podem aparecer no server.log ao ser derrotado
# ==============================================================================
BOSS_TIMELINE: List[Dict[str, Any]] = [
    # --- PRE-HARDMODE ---
    {
        "id": "king_slime",
        "name": "King Slime",
        "mod": "Vanilla",
        "phase": "pre_hardmode",
        "summon": "Slime Crown (ou fim da Slime Rain)",
        "biome": "Qualquer bioma na Superfície",
        "twld_keys": ["downedSlimeKing", "Terraria/KingSlime"],
        "log_aliases": ["King Slime", "Rei Geleia"],
    },
    {
        "id": "desert_scourge",
        "name": "Desert Scourge",
        "mod": "CalamityMod",
        "phase": "pre_hardmode",
        "summon": "Desert Medallion",
        "biome": "Deserto (Qualquer horário)",
        "twld_keys": ["downedDesertScourge", "CalamityMod/DesertScourge"],
        "log_aliases": ["Desert Scourge"],
    },
    {
        "id": "eye_of_cthulhu",
        "name": "Eye of Cthulhu",
        "mod": "Vanilla",
        "phase": "pre_hardmode",
        "summon": "Suspicious Looking Eye (à noite)",
        "biome": "Superfície (Somente à Noite)",
        "twld_keys": ["downedBoss1", "Terraria/EyeOfCthulhu"],
        "log_aliases": ["Eye of Cthulhu", "The Eye of Cthulhu", "Olho de Cthulhu"],
    },
    {
        "id": "crabulon",
        "name": "Crabulon",
        "mod": "CalamityMod",
        "phase": "pre_hardmode",
        "summon": "Decapodita Sprout",
        "biome": "Bioma de Cogumelos Brilhantes (Glowing Mushroom)",
        "twld_keys": ["downedCrabulon", "CalamityMod/Crabulon"],
        "log_aliases": ["Crabulon"],
    },
    {
        "id": "evil_boss",
        "name": "Eater of Worlds / Brain of Cthulhu",
        "mod": "Vanilla",
        "phase": "pre_hardmode",
        "summon": "Worm Food / Bloody Spine (ou quebrar 3 Shadow Orbs / Crimson Hearts)",
        "biome": "Corruption ou Crimson",
        "twld_keys": ["downedBoss2", "Terraria/EaterOfWorlds", "Terraria/BrainOfCthulhu"],
        "log_aliases": ["Eater of Worlds", "Brain of Cthulhu", "Devorador de Mundos", "Cérebro de Cthulhu"],
    },
    {
        "id": "calamity_evil",
        "name": "The Hive Mind / The Perforators",
        "mod": "CalamityMod",
        "phase": "pre_hardmode",
        "summon": "Teratoma (Corruption) / Bloody Worm Food (Crimson) ou matar Cisto",
        "biome": "Corruption ou Crimson",
        "twld_keys": ["downedHiveMind", "downedPerforator", "CalamityMod/HiveMind", "CalamityMod/Perforator"],
        "log_aliases": ["The Hive Mind", "Hive Mind", "The Perforators", "The Perforator Hive"],
    },
    {
        "id": "queen_bee",
        "name": "Queen Bee",
        "mod": "Vanilla",
        "phase": "pre_hardmode",
        "summon": "Abeemination (ou quebrar Larva na Colmeia)",
        "biome": "Selva Subterrânea (Underground Jungle)",
        "twld_keys": ["downedQueenBee", "Terraria/QueenBee"],
        "log_aliases": ["Queen Bee", "Abelha Rainha"],
    },
    {
        "id": "deerclops",
        "name": "Deerclops",
        "mod": "Vanilla",
        "phase": "pre_hardmode",
        "summon": "Deer Thing (ou natural em Nevasca à meia-noite)",
        "biome": "Tundra / Bioma de Neve",
        "twld_keys": ["downedDeerclops", "Terraria/Deerclops"],
        "log_aliases": ["Deerclops"],
    },
    {
        "id": "skeletron",
        "name": "Skeletron",
        "mod": "Vanilla",
        "phase": "pre_hardmode",
        "summon": "Conversar com o Old Man à noite (ou Clothier Voodoo Doll)",
        "biome": "Entrada da Dungeon (Somente à Noite)",
        "twld_keys": ["downedBoss3", "Terraria/Skeletron"],
        "log_aliases": ["Skeletron"],
    },
    {
        "id": "slime_god",
        "name": "The Slime God",
        "mod": "CalamityMod",
        "phase": "pre_hardmode",
        "summon": "Overloaded Sludge",
        "biome": "Qualquer bioma (Recomendado: Arena ampla na Superfície)",
        "twld_keys": ["downedSlimeGod", "CalamityMod/SlimeGod"],
        "log_aliases": ["The Slime God", "Slime God"],
    },
    {
        "id": "wall_of_flesh",
        "name": "Wall of Flesh",
        "mod": "Vanilla",
        "phase": "pre_hardmode",
        "summon": "Jogar Guide Voodoo Doll na lava (com o Guia vivo)",
        "biome": "Submundo (The Underworld)",
        "twld_keys": ["hardMode", "Terraria/WallOfFlesh"],
        "log_aliases": [
            "Wall of Flesh",
            "Parede de Carne",
            "The spirits of light and dark have been released",
        ],
    },
    # --- HARDMODE ---
    {
        "id": "queen_slime",
        "name": "Queen Slime",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Gelatin Crystal",
        "biome": "The Hallow",
        "twld_keys": ["downedQueenSlime", "Terraria/QueenSlime"],
        "log_aliases": ["Queen Slime", "Geleia Rainha"],
    },
    {
        "id": "cryogen",
        "name": "Cryogen",
        "mod": "CalamityMod",
        "phase": "hardmode",
        "summon": "Cryo Key",
        "biome": "Tundra / Bioma de Neve",
        "twld_keys": ["downedCryogen", "CalamityMod/Cryogen"],
        "log_aliases": ["Cryogen"],
    },
    {
        "id": "the_twins",
        "name": "The Twins",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Mechanical Eye (à noite)",
        "biome": "Superfície (Somente à Noite)",
        "twld_keys": ["downedMechBoss2", "Terraria/TheTwins"],
        "log_aliases": ["The Twins", "Os Gêmeos"],
    },
    {
        "id": "aquatic_scourge",
        "name": "Aquatic Scourge",
        "mod": "CalamityMod",
        "phase": "hardmode",
        "summon": "Seafood",
        "biome": "Mar Sulfuroso (Sulphurous Sea)",
        "twld_keys": ["downedAquaticScourge", "CalamityMod/AquaticScourge"],
        "log_aliases": ["Aquatic Scourge"],
    },
    {
        "id": "the_destroyer",
        "name": "The Destroyer",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Mechanical Worm (à noite)",
        "biome": "Superfície (Somente à Noite)",
        "twld_keys": ["downedMechBoss1", "Terraria/TheDestroyer"],
        "log_aliases": ["The Destroyer", "O Destruidor"],
    },
    {
        "id": "brimstone_elemental",
        "name": "Brimstone Elemental",
        "mod": "CalamityMod",
        "phase": "hardmode",
        "summon": "Charred Idol",
        "biome": "Brimstone Crag (Submundo Esquerdo)",
        "twld_keys": ["downedBrimstoneElemental", "CalamityMod/BrimstoneElemental"],
        "log_aliases": ["Brimstone Elemental"],
    },
    {
        "id": "skeletron_prime",
        "name": "Skeletron Prime",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Mechanical Skull (à noite)",
        "biome": "Superfície (Somente à Noite)",
        "twld_keys": ["downedMechBoss3", "Terraria/SkeletronPrime"],
        "log_aliases": ["Skeletron Prime"],
    },
    {
        "id": "calamitas_clone",
        "name": "Calamitas Clone",
        "mod": "CalamityMod",
        "phase": "hardmode",
        "summon": "Eye of Desolation (à noite)",
        "biome": "Superfície (Somente à Noite)",
        "twld_keys": ["downedCalamitasClone", "CalamityMod/CalamitasClone"],
        "log_aliases": ["Calamitas Clone", "Cataclysm", "Catastrophe"],
    },
    {
        "id": "plantera",
        "name": "Plantera",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Quebrar Plantera's Bulb (ou Portabulb)",
        "biome": "Selva Subterrânea (Underground Jungle)",
        "twld_keys": ["downedPlantBoss", "Terraria/Plantera"],
        "log_aliases": ["Plantera"],
    },
    {
        "id": "leviathan_anahita",
        "name": "Leviathan and Anahita",
        "mod": "CalamityMod",
        "phase": "hardmode",
        "summon": "Derrotar '???' no Oceano (ou Anahita Lure)",
        "biome": "Oceano",
        "twld_keys": ["downedLeviathan", "CalamityMod/Leviathan"],
        "log_aliases": ["Leviathan and Anahita", "The Leviathan", "Anahita"],
    },
    {
        "id": "astrum_aureus",
        "name": "Astrum Aureus",
        "mod": "CalamityMod",
        "phase": "hardmode",
        "summon": "Astral Chunk (à noite)",
        "biome": "Infecção Astral (Astral Infection - Somente à Noite)",
        "twld_keys": ["downedAstrumAureus", "CalamityMod/AstrumAureus"],
        "log_aliases": ["Astrum Aureus"],
    },
    {
        "id": "golem",
        "name": "Golem",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Lihzahrd Power Cell no Lihzahrd Altar",
        "biome": "Templo da Selva (Jungle Temple)",
        "twld_keys": ["downedGolemBoss", "Terraria/Golem"],
        "log_aliases": ["Golem"],
    },
    {
        "id": "plaguebringer_goliath",
        "name": "The Plaguebringer Goliath",
        "mod": "CalamityMod",
        "phase": "hardmode",
        "summon": "Abombination",
        "biome": "Selva (Jungle)",
        "twld_keys": ["downedPlaguebringer", "CalamityMod/PlaguebringerGoliath"],
        "log_aliases": ["The Plaguebringer Goliath", "Plaguebringer Goliath"],
    },
    {
        "id": "empress_of_light",
        "name": "Empress of Light",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Matar Prismatic Lacewing",
        "biome": "The Hallow (Noite ou Dia para Terraprisma)",
        "twld_keys": ["downedEmpressOfLight", "Terraria/EmpressOfLight"],
        "log_aliases": ["Empress of Light", "Imperatriz da Luz"],
    },
    {
        "id": "duke_fishron",
        "name": "Duke Fishron",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Pescar com Truffle Worm no Oceano",
        "biome": "Oceano",
        "twld_keys": ["downedFishron", "Terraria/DukeFishron"],
        "log_aliases": ["Duke Fishron", "Duque Peixe-Dragão"],
    },
    {
        "id": "ravager",
        "name": "Ravager",
        "mod": "CalamityMod",
        "phase": "hardmode",
        "summon": "Death Whistle",
        "biome": "Qualquer bioma na Superfície",
        "twld_keys": ["downedRavager", "CalamityMod/Ravager"],
        "log_aliases": ["Ravager"],
    },
    {
        "id": "lunatic_cultist",
        "name": "Lunatic Cultist",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Matar os 4 Cultistas na entrada da Dungeon (ou Eidolon Tablet)",
        "biome": "Entrada da Dungeon",
        "twld_keys": ["downedAncientCultist", "Terraria/LunaticCultist"],
        "log_aliases": ["Lunatic Cultist", "Cultista Lunático"],
    },
    {
        "id": "astrum_deus",
        "name": "Astrum Deus",
        "mod": "CalamityMod",
        "phase": "hardmode",
        "summon": "Titan Heart / Starcore no Astral Beacon (à noite)",
        "biome": "Infecção Astral (Somente à Noite)",
        "twld_keys": ["downedAstrumDeus", "CalamityMod/AstrumDeus"],
        "log_aliases": ["Astrum Deus"],
    },
    {
        "id": "astrageldon",
        "name": "Astrageldon",
        "mod": "CatalystMod",
        "phase": "hardmode",
        "summon": "Astral Transmogrifier (ATENÇÃO: Derrotar ANTES do Moon Lord!)",
        "biome": "Infecção Astral",
        "twld_keys": ["downedAstrageldon", "CatalystMod/Astrageldon"],
        "log_aliases": ["Astrageldon"],
    },
    {
        "id": "moon_lord",
        "name": "Moon Lord",
        "mod": "Vanilla",
        "phase": "hardmode",
        "summon": "Destruir os 4 Pilares Celestiais ou Celestial Sigil",
        "biome": "Qualquer bioma",
        "twld_keys": ["downedMoonlord", "Terraria/MoonLord"],
        "log_aliases": ["Moon Lord", "Senhor da Lua"],
    },
    # --- POST-MOON LORD (GODSEEKER / ENDGAME) ---
    {
        "id": "profaned_guardians",
        "name": "Profaned Guardians",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Profaned Shard (durante o dia)",
        "biome": "The Hallow ou Submundo (Somente de Dia)",
        "twld_keys": ["downedGuardians", "CalamityMod/ProfanedGuardians"],
        "log_aliases": ["Profaned Guardians", "Guardian Commander"],
    },
    {
        "id": "dragonfolly",
        "name": "Dragonfolly",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Exotic Pheromones",
        "biome": "Selva (Jungle)",
        "twld_keys": ["downedDragonfolly", "downedBumblebirb", "CalamityMod/Dragonfolly"],
        "log_aliases": ["Dragonfolly", "The Dragonfolly", "Bumblebirb"],
    },
    {
        "id": "providence",
        "name": "Providence, the Profaned Goddess",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Profaned Core",
        "biome": "The Hallow (Dia) ou Submundo (Dia) | Noite = Modo Enraged",
        "twld_keys": ["downedProvidence", "CalamityMod/Providence"],
        "log_aliases": ["Providence, the Profaned Goddess", "Providence"],
    },
    {
        "id": "storm_weaver",
        "name": "Storm Weaver",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Rune of Kos",
        "biome": "Espaço (Space)",
        "twld_keys": ["downedStormWeaver", "CalamityMod/StormWeaver"],
        "log_aliases": ["Storm Weaver"],
    },
    {
        "id": "ceaseless_void",
        "name": "Ceaseless Void",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Rune of Kos",
        "biome": "Dungeon",
        "twld_keys": ["downedCeaselessVoid", "CalamityMod/CeaselessVoid"],
        "log_aliases": ["Ceaseless Void"],
    },
    {
        "id": "signus",
        "name": "Signus, Envoy of the Devourer",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Rune of Kos",
        "biome": "Submundo (The Underworld)",
        "twld_keys": ["downedSignus", "CalamityMod/Signus"],
        "log_aliases": ["Signus, Envoy of the Devourer", "Signus"],
    },
    {
        "id": "polterghast",
        "name": "Polterghast",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Necroplasmic Beacon (ou matar 30 Phantom Spirits)",
        "biome": "Dungeon",
        "twld_keys": ["downedPolterghast", "CalamityMod/Polterghast"],
        "log_aliases": ["Polterghast"],
    },
    {
        "id": "old_duke",
        "name": "The Old Duke",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Pescar com Bloodworm (ou fim da Acid Rain Tier 3)",
        "biome": "Mar Sulfuroso (Sulphurous Sea)",
        "twld_keys": ["downedOldDuke", "CalamityMod/OldDuke"],
        "log_aliases": ["The Old Duke", "Old Duke"],
    },
    {
        "id": "devourer_of_gods",
        "name": "The Devourer of Gods",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Cosmic Worm",
        "biome": "Qualquer bioma (Recomendado: Plataforma longa no Céu)",
        "twld_keys": ["downedDoG", "CalamityMod/DevourerOfGods"],
        "log_aliases": ["The Devourer of Gods", "Devourer of Gods"],
    },
    {
        "id": "yharon",
        "name": "Yharon, Dragon of Rebirth",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Blessed Phoenix Egg",
        "biome": "Qualquer bioma (Superfície / Selva)",
        "twld_keys": ["downedYharon", "CalamityMod/Yharon"],
        "log_aliases": ["Yharon, Dragon of Rebirth", "Yharon"],
    },
    {
        "id": "exo_mechs",
        "name": "Exo Mechs (Draedon)",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Codebreaker Completo (Comunicar com Draedon)",
        "biome": "Qualquer bioma (Arena de mundo inteiro recomendada)",
        "twld_keys": ["downedExoMechs", "downedThanatos", "downedAres", "downedArtemisAndApollo", "CalamityMod/ExoMechs"],
        "log_aliases": ["Exo Mechs", "Draedon", "XF-09 Ares", "XM-05 Thanatos", "XS-01 Artemis"],
    },
    {
        "id": "supreme_calamitas",
        "name": "Supreme Witch, Calamitas",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Altar of the Accursed com Ashes of Calamity (ou Ceremonial Urn)",
        "biome": "Qualquer bioma",
        "twld_keys": ["downedCalamitas", "CalamityMod/SupremeCalamitas"],
        "log_aliases": ["Supreme Witch, Calamitas", "Supreme Calamitas"],
    },
    {
        "id": "primordial_wyrm",
        "name": "Primordial Wyrm",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Usar Rod of Discord / Normality Relocator no fundo do Abismo (Camada 4)",
        "biome": "Abismo Camada 4 (The Void)",
        "twld_keys": ["downedPrimordialWyrm", "downedAdultEidolonWyrm", "CalamityMod/PrimordialWyrm"],
        "log_aliases": ["Primordial Wyrm", "Adult Eidolon Wyrm"],
    },
    {
        "id": "goozma",
        "name": "Goozma",
        "mod": "CalamityHunt",
        "phase": "post_moonlord",
        "summon": "Jogar Overloaded Sludge no Slime Monsoon enquanto chove",
        "biome": "Superfície (Durante Chuva)",
        "twld_keys": ["downedGoozma", "CalamityHunt/Goozma"],
        "log_aliases": ["Goozma"],
    },
    {
        "id": "mars",
        "name": "Mars, the Artificial God",
        "mod": "NoxusBoss",
        "phase": "post_moonlord",
        "summon": "Questline de Solyn (Pós-Draedon)",
        "biome": "Espaço / Questline Wrath of the Gods",
        "twld_keys": ["downedMars", "NoxusBoss/Mars"],
        "log_aliases": ["Mars"],
    },
    {
        "id": "avatar_of_emptiness",
        "name": "Avatar of Emptiness",
        "mod": "NoxusBoss",
        "phase": "post_moonlord",
        "summon": "Ativar o Genesis completo (Questline Wrath of the Gods)",
        "biome": "Dimensão do Vazio",
        "twld_keys": ["downedAvatar", "downedNoxus", "NoxusBoss/AvatarOfEmptiness"],
        "log_aliases": ["Avatar of Emptiness", "Entropic God, Noxus"],
    },
    {
        "id": "nameless_deity",
        "name": "Nameless Deity of Light",
        "mod": "NoxusBoss",
        "phase": "post_moonlord",
        "summon": "Completar o Genesis após derrotar o Avatar of Emptiness",
        "biome": "Eternal Garden (Jardim Eterno)",
        "twld_keys": ["downedNamelessDeity", "NoxusBoss/NamelessDeity"],
        "log_aliases": ["Nameless Deity of Light", "Nameless Deity"],
    },
    {
        "id": "boss_rush",
        "name": "Boss Rush",
        "mod": "CalamityMod",
        "phase": "post_moonlord",
        "summon": "Terminus (Baú do fundo do Abismo)",
        "biome": "Qualquer bioma",
        "twld_keys": ["downedBossRush", "CalamityMod/BossRush"],
        "log_aliases": ["Boss Rush"],
    },
]

# ==============================================================================
# 2. MARCOS PRÉ-DEFINIDOS DA CAMPANHA (EXPLORAÇÃO, LABS & EVENTOS)
# ==============================================================================
CAMPAIGN_MILESTONES: List[Dict[str, str]] = [
    {
        "id": "shimmer",
        "name": "Aether / Shimmer",
        "phase": "pre_hardmode",
        "desc": "Localizar o bioma de Shimmer no subterrâneo (lado da Selva) para transmutações permanentes",
    },
    {
        "id": "goblin_army",
        "name": "Goblin Army & Goblin Tinkerer",
        "phase": "pre_hardmode",
        "desc": "Vencer a invasão Goblin e resgatar o NPC Goblin Tinkerer no subterrâneo",
    },
    {
        "id": "sunken_sea",
        "name": "Sunken Sea & Giant Clam",
        "phase": "pre_hardmode",
        "desc": "Explorar o Mar Submerso abaixo do Deserto (após Desert Scourge) e derrotar a Giant Clam",
    },
    {
        "id": "lab_sunken",
        "name": "Draedon Lab: Sunken Sea",
        "phase": "pre_hardmode",
        "desc": "Encontrar o Laboratório de Draedon no Sunken Sea e coletar o Encrypted Schematic (Sunken Sea)",
    },
    {
        "id": "lab_planetoid",
        "name": "Draedon Lab: Planetoid",
        "phase": "pre_hardmode",
        "desc": "Subir ao Espaço, localizar o Planetoide Principal e coletar o Encrypted Schematic (Planetoid)",
    },
    {
        "id": "sulphurous_abyss",
        "name": "Sulphurous Sea & Abyss (Camadas 1-2)",
        "phase": "pre_hardmode",
        "desc": "Concluir Acid Rain Tier 1 e saquear os baús do Abismo com a Shadow Key (Pós-Skeletron)",
    },
    {
        "id": "brimstone_crag",
        "name": "Brimstone Crag & Lab do Submundo",
        "phase": "pre_hardmode",
        "desc": "Explorar o Brimstone Crag no Submundo esquerdo e coletar o Encrypted Schematic (Underworld)",
    },
    {
        "id": "astral_biome",
        "name": "Astral Infection",
        "phase": "hardmode",
        "desc": "Explorar o bioma de Infecção Astral surgido na superfície ao entrar no Hardmode",
    },
    {
        "id": "lab_ice",
        "name": "Draedon Lab: Tundra / Ice",
        "phase": "hardmode",
        "desc": "Localizar o Laboratório de Draedon na Tundra Subterrânea e coletar o Schematic (Ice)",
    },
    {
        "id": "lab_jungle",
        "name": "Draedon Lab: Jungle",
        "phase": "hardmode",
        "desc": "Localizar o Laboratório de Draedon na Selva Subterrânea e coletar o Schematic (Jungle)",
    },
    {
        "id": "solar_eclipse",
        "name": "Solar Eclipse (Pós-Plantera / Calamitas Clone)",
        "phase": "hardmode",
        "desc": "Farmar Darksun Fragments no Eclipse Solar após derrotar Plantera e Calamitas Clone",
    },
    {
        "id": "abyss_void",
        "name": "Abyss Layer 4 (The Void) & Terminus",
        "phase": "post_moonlord",
        "desc": "Descer até a última camada do Abismo (Pós-Polterghast) para obter recursos abissais e o Terminus",
    },
]

PHASE_LABELS = {
    "pre_hardmode": "🌱 Pre-Hardmode",
    "hardmode": "⚔️ Hardmode",
    "post_moonlord": "🌌 Post-Moon Lord (Godseeker)",
}


def normalize_text(text: str) -> str:
    if not text:
        return ""
    nfkd = unicodedata.normalize("NFKD", text)
    ascii_str = "".join(c for c in nfkd if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", " ", ascii_str.lower()).strip()


def get_paths() -> Tuple[str, str, str, str]:
    world_name = os.environ.get("TMOD_WORLDNAME", "MundoPrincipal")
    worlds_dir = os.environ.get("TMOD_WORLDS_DIR", "/data/tModLoader/Worlds")
    mods_dir = os.environ.get("TMOD_MODS_DIR", "/data/tModLoader/Mods")
    if not os.path.exists(worlds_dir) and os.path.exists("Worlds"):
        worlds_dir = os.path.abspath("Worlds")
    if not os.path.exists(mods_dir) and os.path.exists("Mods"):
        mods_dir = os.path.abspath("Mods")
    state_file = os.path.join(worlds_dir, f"{world_name}_progression.json")
    twld_file = os.path.join(worlds_dir, f"{world_name}.twld")
    enabled_json = os.path.join(mods_dir, "enabled.json")
    return world_name, state_file, twld_file, enabled_json


def get_enabled_mods() -> List[str]:
    _, _, _, enabled_json = get_paths()
    if os.path.exists(enabled_json):
        try:
            with open(enabled_json, "r", encoding="utf-8", errors="ignore") as f:
                data = json.load(f)
                if isinstance(data, list):
                    return [str(m) for m in data]
        except Exception:
            pass
    return []


def get_active_boss_timeline() -> List[Dict[str, Any]]:
    """
    Retorna a linha do tempo de bosses aplicável ao servidor.
    Vanilla e CalamityMod ficam sempre ativos por padrão (já que o servidor é focado em Calamity),
    assim como o próprio Nameless Deity (chefe temático do bot). Addons opcionais (CatalystMod,
    CalamityHunt e demais bosses de NoxusBoss) entram automaticamente quando presentes em enabled.json
    ou se já estiverem marcados como derrotados.
    """
    enabled = set(get_enabled_mods())
    state = load_state()
    defeated_ids = set(state.get("bosses_defeated", {}).keys())

    active = []
    for boss in BOSS_TIMELINE:
        mod = boss["mod"]
        b_id = boss["id"]
        if mod in ("Vanilla", "CalamityMod") or b_id == "nameless_deity":
            active.append(boss)
        elif mod in enabled or b_id in defeated_ids:
            active.append(boss)
    return active


def load_state() -> Dict[str, Any]:
    _, state_file, _, _ = get_paths()
    default_state: Dict[str, Any] = {
        "bosses_defeated": {},
        "milestones_completed": {},
        "custom_goals": [],
        "updated_at": None,
    }
    if os.path.exists(state_file):
        try:
            with open(state_file, "r", encoding="utf-8", errors="ignore") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    default_state.update(data)
        except Exception:
            pass
    return default_state


def save_state(state: Dict[str, Any]) -> None:
    _, state_file, _, _ = get_paths()
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    state["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    tmp_file = state_file + ".tmp"
    with open(tmp_file, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    os.replace(tmp_file, state_file)


# ==============================================================================
# 3. PARSER BINÁRIO NBT (.twld do tModLoader)
# ==============================================================================
class _NBTReader:
    def __init__(self, buf: bytes):
        self.stream = io.BytesIO(buf)

    def _read(self, n: int) -> bytes:
        b = self.stream.read(n)
        if len(b) < n:
            raise EOFError()
        return b

    def read_byte(self) -> int:
        return struct.unpack(">b", self._read(1))[0]

    def read_ubyte(self) -> int:
        return struct.unpack(">B", self._read(1))[0]

    def read_short(self) -> int:
        return struct.unpack(">h", self._read(2))[0]

    def read_int(self) -> int:
        return struct.unpack(">i", self._read(4))[0]

    def read_long(self) -> int:
        return struct.unpack(">q", self._read(8))[0]

    def read_float(self) -> float:
        return struct.unpack(">f", self._read(4))[0]

    def read_double(self) -> float:
        return struct.unpack(">d", self._read(8))[0]

    def read_string(self) -> str:
        length = struct.unpack(">H", self._read(2))[0]
        return self._read(length).decode("utf-8", errors="replace")

    def read_payload(self, tag_type: int) -> Any:
        if tag_type == 1:
            return self.read_byte()
        if tag_type == 2:
            return self.read_short()
        if tag_type == 3:
            return self.read_int()
        if tag_type == 4:
            return self.read_long()
        if tag_type == 5:
            return self.read_float()
        if tag_type == 6:
            return self.read_double()
        if tag_type == 7:
            length = self.read_int()
            return self._read(max(0, length))
        if tag_type == 8:
            return self.read_string()
        if tag_type == 9:
            sub_type = self.read_ubyte()
            length = self.read_int()
            return [self.read_payload(sub_type) for _ in range(max(0, length))]
        if tag_type == 10:
            compound = {}
            while True:
                t = self.read_ubyte()
                if t == 0:
                    break
                name = self.read_string()
                compound[name] = self.read_payload(t)
            return compound
        if tag_type == 11:
            length = self.read_int()
            return [self.read_int() for _ in range(max(0, length))]
        if tag_type == 12:
            length = self.read_int()
            return [self.read_long() for _ in range(max(0, length))]
        raise ValueError(f"Tag NBT desconhecida: {tag_type}")

    def parse_root(self) -> Dict[str, Any]:
        root_type = self.read_ubyte()
        if root_type != 10:
            return {}
        _ = self.read_string()
        return self.read_payload(10)


def _collect_truthy_keys_from_nbt(node: Any, found: set) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, int) and v != 0:
                found.add(k)
            elif isinstance(v, str) and v.strip():
                found.add(v.strip())
            elif isinstance(v, (dict, list)):
                if k in ("downed", "downedFlags", "DownedBosses", "downedBosses") and isinstance(v, list):
                    for item in v:
                        if isinstance(item, str):
                            found.add(item)
                _collect_truthy_keys_from_nbt(v, found)
    elif isinstance(node, list):
        for item in node:
            if isinstance(item, str):
                found.add(item)
            elif isinstance(item, (dict, list)):
                _collect_truthy_keys_from_nbt(item, found)


def extract_downed_keys_from_twld(twld_path: str) -> set:
    """
    Descompacta o arquivo .twld (GZip NBT) e retorna o conjunto de flags de bosses derrotados.
    """
    found: set = set()
    if not os.path.exists(twld_path):
        return found
    try:
        with open(twld_path, "rb") as f:
            raw = f.read()
        if raw[:2] == b"\x1f\x8b":
            raw = gzip.decompress(raw)
        reader = _NBTReader(raw)
        root = reader.parse_root()
        _collect_truthy_keys_from_nbt(root, found)
    except Exception:
        pass
    return found


def sync_from_world_files() -> List[Dict[str, Any]]:
    """
    Sincroniza flags de bosses derrotados a partir do arquivo .twld com o estado persistido.
    Retorna a lista de novos bosses detectados nesta sincronização.
    """
    _, _, twld_file, _ = get_paths()
    downed_keys = extract_downed_keys_from_twld(twld_file)
    if not downed_keys:
        return []

    state = load_state()
    defeated = state.setdefault("bosses_defeated", {})
    newly_defeated = []
    now_str = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")

    for boss in BOSS_TIMELINE:
        b_id = boss["id"]
        if b_id in defeated:
            continue
        if any(k in downed_keys for k in boss.get("twld_keys", [])):
            defeated[b_id] = {"at": now_str, "by": "Arquivo do Mundo (.twld)"}
            newly_defeated.append(boss)

    if newly_defeated:
        save_state(state)
    return newly_defeated


# ==============================================================================
# 4. CONSULTAS, BUSCA FUZZY E MARCAÇÃO DE OBJETIVOS
# ==============================================================================
def get_next_boss(state: Optional[Dict[str, Any]] = None) -> Optional[Dict[str, Any]]:
    if state is None:
        state = load_state()
    defeated = state.get("bosses_defeated", {})
    for boss in get_active_boss_timeline():
        if boss["id"] not in defeated:
            return boss
    return None


def get_next_milestone(state: Optional[Dict[str, Any]] = None) -> Optional[Dict[str, str]]:
    if state is None:
        state = load_state()
    completed = state.get("milestones_completed", {})
    for ms in CAMPAIGN_MILESTONES:
        if ms["id"] not in completed:
            return ms
    return None


def find_target(query: str, state: Optional[Dict[str, Any]] = None) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
    """
    Localiza um Boss, Marco da Campanha ou Meta Customizada por ID, número ou nome aproximado.
    Retorna (tipo, objeto), onde tipo in ("boss", "milestone", "custom").
    """
    if state is None:
        state = load_state()
    q_norm = normalize_text(query)
    if not q_norm:
        return None, None

    candidates: List[Tuple[str, Dict[str, Any], List[str]]] = []
    for idx, b in enumerate(get_active_boss_timeline(), start=1):
        keys = [normalize_text(b["id"]), normalize_text(b["name"]), f"b{idx}", str(idx)]
        keys.extend(normalize_text(a) for a in b.get("log_aliases", []))
        candidates.append(("boss", b, keys))

    for idx, m in enumerate(CAMPAIGN_MILESTONES, start=1):
        keys = [normalize_text(m["id"]), normalize_text(m["name"]), f"m{idx}"]
        candidates.append(("milestone", m, keys))

    for idx, c in enumerate(state.get("custom_goals", []), start=1):
        keys = [normalize_text(c["id"]), normalize_text(c["name"]), f"c{idx}"]
        candidates.append(("custom", c, keys))

    # 1. Match exato
    for kind, obj, keys in candidates:
        if q_norm in keys:
            return kind, obj

    # 2. Substring direta
    for kind, obj, keys in candidates:
        if any(q_norm in k or k in q_norm for k in keys if len(k) > 2):
            return kind, obj

    # 3. Fuzzy match
    best_score = 0.0
    best_match: Tuple[Optional[str], Optional[Dict[str, Any]]] = (None, None)
    for kind, obj, keys in candidates:
        for k in keys:
            score = difflib.SequenceMatcher(None, q_norm, k).ratio()
            if score > best_score:
                best_score = score
                best_match = (kind, obj)

    if best_score >= 0.6:
        return best_match
    return None, None


def mark_target(query: str, completed: bool = True, actor: str = "Jogador") -> Tuple[bool, str, Optional[Dict[str, Any]]]:
    state = load_state()
    kind, obj = find_target(query, state)
    if not kind or not obj:
        return (
            False,
            f"Não encontrei nenhum boss ou objetivo correspondente a **`{query}`**. Use `!bosses` ou `!objetivos` para ver a lista.",
            None,
        )

    now_str = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
    target_id = obj["id"]
    target_name = obj["name"]

    if kind == "boss":
        defeated = state.setdefault("bosses_defeated", {})
        if completed:
            defeated[target_id] = {"at": now_str, "by": actor}
            save_state(state)
            nxt = get_next_boss(state)
            nxt_txt = f" Próximo na fila: **{nxt['name']}** ({nxt['biome']})." if nxt else " Todos os bosses foram superados!"
            return True, f"👁️ Boss **{target_name}** marcado como **DERROTADO** por *{actor}*!{nxt_txt}", obj
        else:
            defeated.pop(target_id, None)
            save_state(state)
            return True, f"⏳ Boss **{target_name}** voltou para o estado **PENDENTE**.", obj

    if kind == "milestone":
        ms_map = state.setdefault("milestones_completed", {})
        if completed:
            ms_map[target_id] = {"at": now_str, "by": actor}
            save_state(state)
            return True, f"✨ Marco da Campanha **{target_name}** marcado como **CONCLUÍDO** por *{actor}*!", obj
        else:
            ms_map.pop(target_id, None)
            save_state(state)
            return True, f"⏳ Marco da Campanha **{target_name}** voltou para **PENDENTE**.", obj

    # custom goal
    for item in state.get("custom_goals", []):
        if item["id"] == target_id:
            item["done"] = completed
            item["by"] = actor
            item["at"] = now_str if completed else None
            break
    save_state(state)
    status_label = "CONCLUÍDA" if completed else "PENDENTE"
    return True, f"📌 Meta customizada **{target_name}** marcada como **{status_label}**!", obj


def add_custom_goal(text: str, actor: str = "Jogador") -> Tuple[bool, str]:
    clean = text.strip()
    if not clean:
        return False, "Informe a descrição da meta. Exemplo: `!meta Construir arena no Submundo`"
    state = load_state()
    goals = state.setdefault("custom_goals", [])
    goal_id = f"meta_{len(goals) + 1}_{int(time.time()) % 10000}"
    goals.append(
        {
            "id": goal_id,
            "name": clean,
            "done": False,
            "by": actor,
            "at": None,
        }
    )
    save_state(state)
    return True, f"🌌 Nova meta registrada pelo Observador: **{clean}** (para concluir, use `!marcar {clean}`)."


def remove_custom_goal(query: str) -> Tuple[bool, str]:
    state = load_state()
    goals = state.get("custom_goals", [])
    q_norm = normalize_text(query)
    for i, g in enumerate(goals):
        if q_norm in (normalize_text(g["id"]), normalize_text(g["name"])) or q_norm in normalize_text(g["name"]):
            removed = goals.pop(i)
            save_state(state)
            return True, f"🗑️ Meta customizada **{removed['name']}** removida."
    return False, f"Nenhuma meta customizada encontrada para `{query}`."


# ==============================================================================
# 5. FORMATAÇÃO DE EMBEDS (DISCORD) E RESUMOS (CHAT DO TERRARIA)
# ==============================================================================
def _progress_bar(done: int, total: int, width: int = 14) -> str:
    if total <= 0:
        return "`[──────────────]` 0%"
    pct = int(round((done / total) * 100))
    filled = int(round((done / total) * width))
    bar = "█" * filled + "░" * (width - filled)
    return f"`[{bar}]` **{done}/{total}** ({pct}%)"


def build_summary_line() -> str:
    sync_from_world_files()
    state = load_state()
    timeline = get_active_boss_timeline()
    defeated = state.get("bosses_defeated", {})
    done_count = sum(1 for b in timeline if b["id"] in defeated)
    nxt = get_next_boss(state)
    if nxt:
        return (
            f"👁️ **Progresso Cósmico:** `{done_count}/{len(timeline)}` Bosses derrotados • "
            f"🎯 **Próximo Boss:** `{nxt['name']}` ({nxt['biome']})"
        )
    return f"👁️ **Progresso Cósmico:** `{done_count}/{len(timeline)}` Bosses derrotados • 🏆 **Todos os testes superados!**"


def build_progress_embed() -> Dict[str, Any]:
    sync_from_world_files()
    state = load_state()
    timeline = get_active_boss_timeline()
    defeated = state.get("bosses_defeated", {})
    ms_done = state.get("milestones_completed", {})
    custom_goals = state.get("custom_goals", [])

    done_bosses = [b for b in timeline if b["id"] in defeated]
    nxt_boss = get_next_boss(state)
    nxt_ms = get_next_milestone(state)

    current_phase = nxt_boss["phase"] if nxt_boss else "post_moonlord"
    phase_title = PHASE_LABELS.get(current_phase, current_phase)

    fields = [
        {
            "name": "📊 Progresso de Bosses",
            "value": _progress_bar(len(done_bosses), len(timeline)),
            "inline": True,
        },
        {
            "name": "🧭 Era Atual do Mundo",
            "value": f"**{phase_title}**",
            "inline": True,
        },
    ]

    if nxt_boss:
        fields.append(
            {
                "name": "🎯 Próximo Passo na Linha do Tempo (Boss)",
                "value": (
                    f"🔥 **{nxt_boss['name']}** *({nxt_boss['mod']})*\n"
                    f"🧪 **Como Invocar:** `{nxt_boss['summon']}`\n"
                    f"🗺️ **Bioma / Condição:** {nxt_boss['biome']}"
                ),
                "inline": False,
            }
        )
    else:
        fields.append(
            {
                "name": "🏆 Panteão Concluído!",
                "value": "Todos os Bosses da linha do tempo foram derrotados! Vocês passaram no teste final.",
                "inline": False,
            }
        )

    if nxt_ms:
        fields.append(
            {
                "name": "🗺️ Próximo Marco de Exploração Sugerido",
                "value": f"🔹 **{nxt_ms['name']}** — {nxt_ms['desc']}\n*(Use `/marcar {nxt_ms['id']}` ou `!marcar {nxt_ms['id']}` quando concluir)*",
                "inline": False,
            }
        )

    if done_bosses:
        recent = done_bosses[-5:]
        recent_lines = [f"✅ **{b['name']}**" for b in recent]
        fields.append(
            {
                "name": f"⚔️ Últimos Bosses Abatidos ({len(done_bosses)} no total)",
                "value": "\n".join(recent_lines),
                "inline": True,
            }
        )

    done_ms_count = len(ms_done)
    done_custom = sum(1 for g in custom_goals if g.get("done"))
    obj_summary = f"Marcos da Campanha: **{done_ms_count}/{len(CAMPAIGN_MILESTONES)}**"
    if custom_goals:
        obj_summary += f"\nMetas do Grupo: **{done_custom}/{len(custom_goals)}**"
    fields.append(
        {
            "name": "📜 Objetivos & Marcos",
            "value": obj_summary,
            "inline": True,
        }
    )

    return {
        "title": "👁️ Nameless Deity • Registro Cósmico de Progressão",
        "description": (
            "*\"Eu observo cada passo da sua jornada através das eras. "
            "Nenhum desafio deve ser enfrentado nas sombras; avancem juntos.\"*"
        ),
        "color": COLOR_COSMIC_GOLD,
        "fields": fields,
        "footer": {
            "text": "Comandos: /progresso • /proximo • /bosses • /objetivos • /marcar • /meta (ou com ! no chat do jogo)"
        },
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def build_next_step_embed() -> Dict[str, Any]:
    sync_from_world_files()
    state = load_state()
    timeline = get_active_boss_timeline()
    defeated = state.get("bosses_defeated", {})
    pending = [b for b in timeline if b["id"] not in defeated]
    nxt_ms = get_next_milestone(state)

    if not pending:
        return {
            "title": "👁️ Nameless Deity • Julgamento Concluído",
            "description": "✨ **Não restam mais Bosses pendentes nesta realidade.** Vocês superaram todos os desafios!",
            "color": COLOR_COSMIC_GREEN,
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }

    current = pending[0]
    upcoming = pending[1:4]

    fields = [
        {
            "name": f"🎯 Alvo Atual: {current['name']} ({current['mod']})",
            "value": (
                f"🧪 **Item / Método de Invocação:** `{current['summon']}`\n"
                f"🗺️ **Bioma / Horário:** {current['biome']}\n"
                f"🧭 **Fase:** {PHASE_LABELS.get(current['phase'], current['phase'])}"
            ),
            "inline": False,
        }
    ]

    if upcoming:
        up_lines = [
            f"`{i}.` **{b['name']}** — *Invocação:* `{b['summon']}` ({b['biome']})"
            for i, b in enumerate(upcoming, start=2)
        ]
        fields.append(
            {
                "name": "⏭️ Próximos na Sequência Linear",
                "value": "\n".join(up_lines),
                "inline": False,
            }
        )

    if nxt_ms:
        fields.append(
            {
                "name": "🧭 Marco de Exploração Paralelo",
                "value": f"**{nxt_ms['name']}**: {nxt_ms['desc']}",
                "inline": False,
            }
        )

    return {
        "title": "👁️ Nameless Deity • O Próximo Desafio na Linha do Tempo",
        "description": "*\"A luz aponta a direção do próximo confronto. Reúnam todos os guerreiros antes de invocar.\"*",
        "color": COLOR_COSMIC_CYAN,
        "fields": fields,
        "footer": {"text": f"Para marcar manualmente após vencer: /marcar {current['id']} ou !marcar {current['name']}"},
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def build_bosses_embed(phase_filter: str = "") -> Dict[str, Any]:
    sync_from_world_files()
    state = load_state()
    timeline = get_active_boss_timeline()
    defeated = state.get("bosses_defeated", {})
    nxt = get_next_boss(state)
    nxt_id = nxt["id"] if nxt else ""

    norm_filter = normalize_text(phase_filter)
    phases_to_show = ["pre_hardmode", "hardmode", "post_moonlord"]
    if norm_filter:
        if "pre" in norm_filter:
            phases_to_show = ["pre_hardmode"]
        elif "post" in norm_filter or "moon" in norm_filter or "god" in norm_filter or "end" in norm_filter:
            phases_to_show = ["post_moonlord"]
        elif "hard" in norm_filter or "hm" in norm_filter:
            phases_to_show = ["hardmode"]

    fields = []
    for phase_key in phases_to_show:
        phase_bosses = [b for b in timeline if b["phase"] == phase_key]
        lines = []
        for b in phase_bosses:
            is_done = b["id"] in defeated
            if is_done:
                icon = "✅"
                line = f"{icon} ~~{b['name']}~~"
            elif b["id"] == nxt_id:
                icon = "🔥"
                line = f"{icon} **{b['name']}** ⬅️ *(PRÓXIMO: `{b['summon']}` | {b['biome']})*"
            else:
                icon = "⏳"
                line = f"{icon} **{b['name']}** — `{b['summon']}` *({b['biome']})*"
            lines.append(line)

        chunk = ""
        part = 1
        for line in lines:
            if len(chunk) + len(line) + 2 > 980:
                fields.append(
                    {
                        "name": f"{PHASE_LABELS[phase_key]} (Parte {part})",
                        "value": chunk.strip(),
                        "inline": False,
                    }
                )
                chunk = ""
                part += 1
            chunk += line + "\n"
        if chunk.strip():
            title = PHASE_LABELS[phase_key] if part == 1 else f"{PHASE_LABELS[phase_key]} (Parte {part})"
            fields.append({"name": title, "value": chunk.strip(), "inline": False})

    done_count = sum(1 for b in timeline if b["id"] in defeated)
    return {
        "title": f"👁️ Caminho Linear de Bosses ({done_count}/{len(timeline)} Derrotados)",
        "description": "Use `/bosses pre`, `/bosses hard` ou `/bosses post` para filtrar uma era específica.",
        "color": COLOR_COSMIC_PURPLE,
        "fields": fields[:25],
        "footer": {"text": "Nameless Deity • Marque ou desmarque com /marcar <nome> ou !marcar <nome>"},
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def build_objectives_embed() -> Dict[str, Any]:
    state = load_state()
    ms_done = state.get("milestones_completed", {})
    custom_goals = state.get("custom_goals", [])

    ms_lines = []
    for m in CAMPAIGN_MILESTONES:
        done = m["id"] in ms_done
        icon = "✅" if done else "⏳"
        title = f"~~{m['name']}~~" if done else f"**{m['name']}**"
        ms_lines.append(f"{icon} `{m['id']}` • {title} — *{m['desc']}*")

    fields = []
    chunk = ""
    part = 1
    for line in ms_lines:
        if len(chunk) + len(line) + 2 > 980:
            fields.append(
                {
                    "name": f"🗺️ Marcos da Campanha (Parte {part})",
                    "value": chunk.strip(),
                    "inline": False,
                }
            )
            chunk = ""
            part += 1
        chunk += line + "\n"
    if chunk.strip():
        name_lbl = "🗺️ Marcos da Campanha" if part == 1 else f"🗺️ Marcos da Campanha (Parte {part})"
        fields.append({"name": name_lbl, "value": chunk.strip(), "inline": False})

    if custom_goals:
        c_lines = []
        for idx, g in enumerate(custom_goals, start=1):
            icon = "✅" if g.get("done") else "⏳"
            title = f"~~{g['name']}~~" if g.get("done") else f"**{g['name']}**"
            c_lines.append(f"{icon} `[c{idx}]` {title} *(por {g.get('by', 'Jogador')})*")
        fields.append(
            {
                "name": "📌 Metas Customizadas do Grupo",
                "value": "\n".join(c_lines)[:1000],
                "inline": False,
            }
        )
    else:
        fields.append(
            {
                "name": "📌 Metas Customizadas do Grupo",
                "value": "Nenhuma meta extra criada ainda. Adicione com `/meta <texto>` ou `!meta <texto>`!",
                "inline": False,
            }
        )

    return {
        "title": "👁️ Nameless Deity • Marcos de Exploração & Metas do Servidor",
        "description": "Conclua objetivos digitando `/marcar <id ou nome>` no Discord ou `!marcar <id ou nome>` no chat do jogo.",
        "color": COLOR_COSMIC_GOLD,
        "fields": fields,
        "footer": {"text": "Exemplos: !marcar shimmer • !marcar lab_jungle • !meta Construir arena para Exo Mechs"},
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def build_boss_defeated_embed(boss: Dict[str, Any], state: Dict[str, Any]) -> Dict[str, Any]:
    timeline = get_active_boss_timeline()
    defeated = state.get("bosses_defeated", {})
    done_count = sum(1 for b in timeline if b["id"] in defeated)
    nxt = get_next_boss(state)

    fields = [
        {
            "name": "⚔️ Boss Derrotado",
            "value": f"**{boss['name']}** *({boss['mod']})*",
            "inline": True,
        },
        {
            "name": "📊 Progresso Total",
            "value": _progress_bar(done_count, len(timeline)),
            "inline": True,
        },
    ]

    if nxt:
        fields.append(
            {
                "name": "🎯 Próximo Passo na Linha do Tempo",
                "value": (
                    f"🔥 **{nxt['name']}** *({nxt['mod']})*\n"
                    f"🧪 **Como Invocar:** `{nxt['summon']}`\n"
                    f"🗺️ **Bioma / Condição:** {nxt['biome']}"
                ),
                "inline": False,
            }
        )
    else:
        fields.append(
            {
                "name": "🏆 Jornada Completa!",
                "value": "Todos os Bosses da trilha linear foram derrotados!",
                "inline": False,
            }
        )

    return {
        "title": f"👁️ O Observador Registra um Abate: {boss['name']}!",
        "description": f"*\"As estrelas testemunharam a queda de **{boss['name']}**. O selo da próxima provação se abre.\"*",
        "color": COLOR_COSMIC_GREEN,
        "fields": fields,
        "footer": {"text": "Nameless Deity • Guardião da Progressão Linear"},
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


# ==============================================================================
# 6. INTEGRAÇÃO COM WEBHOOK DO DISCORD & CHAT DO JOGO (TMUX INJECT)
# ==============================================================================
def send_to_webhook(embed: Dict[str, Any], content: str = "") -> bool:
    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not webhook_url or not webhook_url.startswith("http"):
        return False
    payload: Dict[str, Any] = {
        "username": BOT_NAME,
        "embeds": [embed],
    }
    if content:
        payload["content"] = content
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            webhook_url,
            data=data,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "NamelessDeity-TerrariaBot/1.0",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as _:
            pass
        return True
    except Exception as e:
        print(f"[NAMELESS DEITY] Aviso ao enviar Webhook: {e}", flush=True)
        return False


def say_in_terraria(message: str) -> None:
    """
    Envia uma mensagem visível no chat interno do servidor Terraria via `inject`.
    """
    clean_msg = re.sub(r"[`*_~]", "", message).replace('"', "'")
    for line in clean_msg.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            subprocess.run(["inject", f"say [Nameless Deity] {line}"], timeout=5, check=False)
        except Exception:
            pass


def handle_text_command(raw_cmd: str, actor: str = "Jogador", from_game_chat: bool = False) -> Optional[Dict[str, Any]]:
    """
    Processa comandos vindos do chat do Terraria (!progresso, !proximo, !bosses, !objetivos,
    !marcar, !desmarcar, !meta, !removermeta, !ajuda) ou do Discord.
    Retorna um dicionário {"text": ..., "embed": ...}.
    """
    text = raw_cmd.strip()
    if not text or text[0] not in ("!", "/"):
        return None

    parts = text[1:].strip().split(maxsplit=1)
    cmd = normalize_text(parts[0]) if parts else ""
    arg = parts[1].strip() if len(parts) > 1 else ""

    if cmd in ("progresso", "progress", "status", "conquistas"):
        embed = build_progress_embed()
        summary = re.sub(r"[`*_]", "", build_summary_line())
        if from_game_chat:
            say_in_terraria(summary)
            if send_to_webhook(embed):
                say_in_terraria("Painel completo enviado no canal do Discord!")
        return {"text": "", "embed": embed}

    if cmd in ("proximo", "next", "passo", "guia"):
        embed = build_next_step_embed()
        nxt = get_next_boss()
        if from_game_chat:
            if nxt:
                say_in_terraria(
                    f"Proximo Boss: {nxt['name']} | Invocacao: {nxt['summon']} | Bioma: {nxt['biome']}"
                )
            else:
                say_in_terraria("Todos os Bosses da linha do tempo ja foram derrotados!")
            send_to_webhook(embed)
        return {"text": "", "embed": embed}

    if cmd in ("bosses", "boss", "chefes", "lista"):
        embed = build_bosses_embed(arg)
        if from_game_chat:
            nxt = get_next_boss()
            state = load_state()
            timeline = get_active_boss_timeline()
            done_c = sum(1 for b in timeline if b["id"] in state.get("bosses_defeated", {}))
            say_in_terraria(
                f"Bosses derrotados: {done_c}/{len(timeline)}. "
                + (f"Proximo: {nxt['name']} ({nxt['summon']}). " if nxt else "")
                + "Lista completa enviada no Discord!"
            )
            send_to_webhook(embed)
        return {"text": "", "embed": embed}

    if cmd in ("objetivos", "metas", "marcos", "objectives", "goals"):
        embed = build_objectives_embed()
        if from_game_chat:
            ms = get_next_milestone()
            if ms:
                say_in_terraria(f"Proximo Marco: {ms['name']} ({ms['desc']}). Lista enviada no Discord!")
            else:
                say_in_terraria("Todos os marcos pre-definidos foram concluidos! Lista enviada no Discord.")
            send_to_webhook(embed)
        return {"text": "", "embed": embed}

    if cmd in ("marcar", "concluir", "check", "done", "complete"):
        if not arg:
            msg = "Informe qual boss ou objetivo deseja marcar! Ex: !marcar desert scourge ou !marcar shimmer"
            if from_game_chat:
                say_in_terraria(msg)
            return {"text": f"⚠️ {msg}", "embed": None}
        ok, msg, _ = mark_target(arg, completed=True, actor=actor)
        embed = build_progress_embed() if ok else None
        if from_game_chat:
            say_in_terraria(msg)
            if ok and embed:
                send_to_webhook(embed, content=msg)
        elif ok:
            say_in_terraria(msg)
        return {"text": msg, "embed": embed}

    if cmd in ("desmarcar", "uncheck", "undone", "resetar"):
        if not arg:
            msg = "Informe qual boss ou objetivo deseja desmarcar! Ex: !desmarcar crabulon"
            if from_game_chat:
                say_in_terraria(msg)
            return {"text": f"⚠️ {msg}", "embed": None}
        ok, msg, _ = mark_target(arg, completed=False, actor=actor)
        embed = build_progress_embed() if ok else None
        if from_game_chat:
            say_in_terraria(msg)
            if ok and embed:
                send_to_webhook(embed, content=msg)
        elif ok:
            say_in_terraria(msg)
        return {"text": msg, "embed": embed}

    if cmd in ("meta", "addmeta", "novameta", "goal"):
        ok, msg = add_custom_goal(arg, actor=actor)
        embed = build_objectives_embed() if ok else None
        if from_game_chat:
            say_in_terraria(msg)
            if ok and embed:
                send_to_webhook(embed, content=msg)
        elif ok:
            say_in_terraria(msg)
        return {"text": msg, "embed": embed}

    if cmd in ("removermeta", "delmeta", "rmmeta"):
        ok, msg = remove_custom_goal(arg)
        embed = build_objectives_embed() if ok else None
        if from_game_chat:
            say_in_terraria(msg)
        return {"text": msg, "embed": embed}

    if cmd in ("ajuda", "help", "nameless"):
        help_embed = {
            "title": "👁️ Nameless Deity • Comandos Disponíveis",
            "description": (
                "Você pode usar os comandos tanto no **Discord** (`/` ou `!`) quanto dentro do **Chat do Terraria** (`!`):"
            ),
            "color": COLOR_COSMIC_GOLD,
            "fields": [
                {"name": "`/progresso` ou `!progresso`", "value": "Mostra o resumo geral, barra de progresso e o Próximo Boss.", "inline": False},
                {"name": "`/proximo` ou `!proximo`", "value": "Mostra em detalhes como invocar e em qual bioma enfrentar o Próximo Boss.", "inline": False},
                {"name": "`/bosses [pre|hard|post]` ou `!bosses`", "value": "Exibe a linha do tempo completa de Bosses (Vanilla + Calamity).", "inline": False},
                {"name": "`/objetivos` ou `!objetivos`", "value": "Lista os Marcos da Campanha (Shimmer, Abismo, Labs de Draedon) e Metas do grupo.", "inline": False},
                {"name": "`/marcar <nome>` ou `!marcar <nome>`", "value": "Marca um Boss, Marco ou Meta como concluído (ex: `!marcar shimmer`).", "inline": False},
                {"name": "`/desmarcar <nome>` ou `!desmarcar <nome>`", "value": "Desmarca um Boss, Marco ou Meta de volta para pendente.", "inline": False},
                {"name": "`/meta <texto>` ou `!meta <texto>`", "value": "Cria um novo objetivo importante na lista do servidor.", "inline": False},
            ],
            "footer": {"text": "Nameless Deity • Servidor Dedicado Terraria tModLoader"},
        }
        if from_game_chat:
            say_in_terraria("Comandos: !progresso | !proximo | !bosses | !objetivos | !marcar <nome> | !desmarcar <nome> | !meta <texto>")
        return {"text": "", "embed": help_embed}

    return None


# ==============================================================================
# 7. MONITORAMENTO DE LOGS EM TEMPO REAL (ABATE DE BOSSES + CHAT IN-GAME)
# ==============================================================================
CHAT_REGEX = re.compile(r"^<([^>]{1,40})>\s*([!/].+)$")
DEFEAT_PATTERNS = [
    re.compile(r"(.+?) has been defeated!", re.IGNORECASE),
    re.compile(r"(.+?) have been defeated!", re.IGNORECASE),
    re.compile(r"(.+?) foi derrotado!", re.IGNORECASE),
    re.compile(r"(.+?) foram derrotados!", re.IGNORECASE),
]


def detect_boss_defeat_in_line(line: str) -> Optional[Dict[str, Any]]:
    clean = line.strip()
    if not clean or clean.startswith("<") or "[Nameless Deity]" in clean:
        return None

    # Caso especial: Wall of Flesh libera os espíritos de luz e trevas
    if "the spirits of light and dark have been released" in clean.lower():
        for b in BOSS_TIMELINE:
            if b["id"] == "wall_of_flesh":
                return b

    candidate_name = None
    for pat in DEFEAT_PATTERNS:
        m = pat.search(clean)
        if m:
            candidate_name = m.group(1).strip()
            # Remove prefixos de timestamp de log caso existam
            candidate_name = re.sub(r"^\[.*?\]\s*", "", candidate_name).strip()
            break

    if not candidate_name:
        return None

    cand_norm = normalize_text(candidate_name)
    for boss in BOSS_TIMELINE:
        aliases = [boss["name"]] + boss.get("log_aliases", [])
        for alias in aliases:
            if normalize_text(alias) == cand_norm or normalize_text(alias) in cand_norm:
                return boss
    return None


def process_log_line(line: str) -> None:
    clean = line.strip()
    if not clean:
        return

    # Remove prefixo de hora do server.log se houver, ex: [18:20:00] <Player> !progresso
    stripped_time = re.sub(r"^\[[0-9:.\s]+\]\s*(?:\[[^\]]+\]\s*)*", "", clean)

    chat_match = CHAT_REGEX.match(stripped_time)
    if chat_match:
        player_name = chat_match.group(1).strip()
        if player_name.lower() in ("server", "nameless deity"):
            return
        cmd_text = chat_match.group(2).strip()
        handle_text_command(cmd_text, actor=player_name, from_game_chat=True)
        return

    defeated_boss = detect_boss_defeat_in_line(stripped_time)
    if defeated_boss:
        state = load_state()
        defeated_map = state.setdefault("bosses_defeated", {})
        b_id = defeated_boss["id"]
        if b_id not in defeated_map:
            now_str = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
            defeated_map[b_id] = {"at": now_str, "by": "Combate no Servidor"}
            save_state(state)
            nxt = get_next_boss(state)
            nxt_msg = f"Proximo desafio: {nxt['name']} ({nxt['summon']} - {nxt['biome']})" if nxt else "Todos os bosses foram derrotados!"
            say_in_terraria(f"Abate registrado: {defeated_boss['name']}! {nxt_msg}")
            embed = build_boss_defeated_embed(defeated_boss, state)
            send_to_webhook(embed)


# ==============================================================================
# 8. CLIENTE NATIVO DISCORD BOT (GATEWAY WEBSOCKET + SLASH COMMANDS HTTP v10)
#    (Zero dependências externas — funciona nativamente com stdlib Python 3!)
# ==============================================================================
class _SimpleWebSocket:
    """Cliente WebSocket RFC 6455 sob TLS usando apenas ssl + socket da biblioteca padrão."""

    def __init__(self, url: str, timeout: float = 30.0):
        parsed = urllib.parse.urlparse(url)
        host = parsed.hostname or "gateway.discord.gg"
        port = parsed.port or 443
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query

        raw_sock = socket.create_connection((host, port), timeout=timeout)
        ctx = ssl.create_default_context()
        self.sock = ctx.wrap_socket(raw_sock, server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        handshake = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"User-Agent: NamelessDeity-TerrariaBot/1.0\r\n\r\n"
        )
        self.sock.sendall(handshake.encode("utf-8"))
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(1024)
            if not chunk:
                raise ConnectionError("Handshake WebSocket encerrado prematuramente.")
            resp += chunk
        if b"101" not in resp.split(b"\r\n", 1)[0]:
            raise ConnectionError(f"Resposta inesperada no handshake WebSocket: {resp[:120]!r}")
        self.lock = threading.Lock()

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise EOFError("Conexão WebSocket fechada.")
            buf += chunk
        return buf

    def recv_frame(self) -> Tuple[int, bytes]:
        b1, b2 = self._recv_exact(2)
        opcode = b1 & 0x0F
        masked = bool(b2 & 0x80)
        length = b2 & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._recv_exact(8))[0]
        mask_key = self._recv_exact(4) if masked else b""
        payload = self._recv_exact(length) if length > 0 else b""
        if masked:
            payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
        return opcode, payload

    def send_text(self, text: str) -> None:
        data = text.encode("utf-8")
        self._send_frame(0x1, data)

    def _send_frame(self, opcode: int, data: bytes) -> None:
        header = bytearray([0x80 | (opcode & 0x0F)])
        length = len(data)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack(">H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack(">Q", length))
        mask = os.urandom(4)
        header.extend(mask)
        masked_data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        with self.lock:
            self.sock.sendall(bytes(header) + masked_data)

    def close(self) -> None:
        try:
            self._send_frame(0x8, b"")
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


class NamelessDeityDiscordBot:
    API_BASE = "https://discord.com/api/v10"

    def __init__(self, token: str):
        self.token = token.strip()
        self.app_id: Optional[str] = None
        self.bot_user_id: Optional[str] = None
        self.seq: Optional[int] = None
        self.ws: Optional[_SimpleWebSocket] = None
        self.running = True

    def _api_request(self, method: str, path: str, body: Optional[Any] = None) -> Any:
        url = f"{self.API_BASE}{path}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Authorization": f"Bot {self.token}",
                "Content-Type": "application/json",
                "User-Agent": "DiscordBot (https://github.com/ServerTerraria, 1.0)",
            },
            method=method,
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw else {}

    def register_slash_commands(self, app_id: str) -> None:
        commands = [
            {
                "name": "progresso",
                "description": "👁️ Exibe o painel geral de progressão linear (Bosses, Marcos e Próximo Passo)",
                "type": 1,
            },
            {
                "name": "proximo",
                "description": "🎯 Mostra qual é o Próximo Boss na fila linear, como invocar e em qual bioma lutar",
                "type": 1,
            },
            {
                "name": "bosses",
                "description": "⚔️ Lista a linha do tempo de Bosses (Vanilla + Calamity) com invocação e bioma",
                "type": 1,
                "options": [
                    {
                        "name": "fase",
                        "description": "Filtrar por era (pre, hard ou post)",
                        "type": 3,
                        "required": False,
                        "choices": [
                            {"name": "🌱 Pre-Hardmode", "value": "pre"},
                            {"name": "⚔️ Hardmode", "value": "hard"},
                            {"name": "🌌 Post-Moon Lord", "value": "post"},
                        ],
                    }
                ],
            },
            {
                "name": "objetivos",
                "description": "🗺️ Lista os Marcos da Campanha (Shimmer, Abismo, Labs de Draedon) e Metas do grupo",
                "type": 1,
            },
            {
                "name": "marcar",
                "description": "✅ Marca um Boss, Marco da Campanha ou Meta como concluído",
                "type": 1,
                "options": [
                    {
                        "name": "alvo",
                        "description": "Nome ou ID do boss/objetivo (ex: Desert Scourge, shimmer, lab_jungle)",
                        "type": 3,
                        "required": True,
                    }
                ],
            },
            {
                "name": "desmarcar",
                "description": "⏳ Volta um Boss, Marco da Campanha ou Meta para o estado pendente",
                "type": 1,
                "options": [
                    {
                        "name": "alvo",
                        "description": "Nome ou ID do boss/objetivo",
                        "type": 3,
                        "required": True,
                    }
                ],
            },
            {
                "name": "meta",
                "description": "🌌 Cria um novo objetivo importante personalizado para o servidor",
                "type": 1,
                "options": [
                    {
                        "name": "descricao",
                        "description": "Descrição da meta (ex: Construir arena no Submundo)",
                        "type": 3,
                        "required": True,
                    }
                ],
            },
            {
                "name": "ajuda",
                "description": "📜 Mostra todos os comandos do Nameless Deity (no Discord e no chat do Terraria)",
                "type": 1,
            },
        ]
        try:
            self._api_request("PUT", f"/applications/{app_id}/commands", commands)
            print(f"[NAMELESS DEITY] Slash Commands (/progresso, /proximo, /bosses, /objetivos, /marcar, /meta) registrados no Discord!", flush=True)
        except Exception as e:
            print(f"[NAMELESS DEITY] Aviso ao registrar Slash Commands: {e}", flush=True)

    def handle_interaction(self, interaction: Dict[str, Any]) -> None:
        inter_id = interaction.get("id")
        inter_token = interaction.get("token")
        data = interaction.get("data", {})
        cmd_name = data.get("name", "")
        options = {opt["name"]: opt.get("value", "") for opt in data.get("options", []) if "name" in opt}
        member = interaction.get("member") or {}
        user = member.get("user") or interaction.get("user") or {}
        actor = user.get("global_name") or user.get("username") or "Jogador Discord"

        arg = ""
        if cmd_name == "bosses":
            arg = str(options.get("fase", ""))
        elif cmd_name in ("marcar", "desmarcar"):
            arg = str(options.get("alvo", ""))
        elif cmd_name == "meta":
            arg = str(options.get("descricao", ""))

        raw_cmd = f"/{cmd_name} {arg}".strip()
        res = handle_text_command(raw_cmd, actor=actor, from_game_chat=False)
        if not res:
            return

        resp_data: Dict[str, Any] = {}
        if res.get("text"):
            resp_data["content"] = res["text"]
        if res.get("embed"):
            resp_data["embeds"] = [res["embed"]]

        try:
            self._api_request(
                "POST",
                f"/interactions/{inter_id}/{inter_token}/callback",
                {"type": 4, "data": resp_data},
            )
        except Exception as e:
            print(f"[NAMELESS DEITY] Erro ao responder Slash Command /{cmd_name}: {e}", flush=True)

    def handle_message(self, msg: Dict[str, Any]) -> None:
        author = msg.get("author") or {}
        if author.get("bot"):
            return
        content = (msg.get("content") or "").strip()
        channel_id = msg.get("channel_id")
        if not content or not channel_id:
            return

        # Permite mencionar o bot (ex: "@Nameless Deity progresso") ou usar !progresso
        if self.bot_user_id and content.startswith(f"<@{self.bot_user_id}>"):
            content = content.replace(f"<@{self.bot_user_id}>", "", 1).strip()
            if content and content[0] not in ("!", "/"):
                content = "!" + content
        elif self.bot_user_id and content.startswith(f"<@!{self.bot_user_id}>"):
            content = content.replace(f"<@!{self.bot_user_id}>", "", 1).strip()
            if content and content[0] not in ("!", "/"):
                content = "!" + content

        if content[0] not in ("!", "/"):
            return

        actor = author.get("global_name") or author.get("username") or "Jogador Discord"
        res = handle_text_command(content, actor=actor, from_game_chat=False)
        if not res:
            return

        payload: Dict[str, Any] = {}
        if res.get("text"):
            payload["content"] = res["text"]
        if res.get("embed"):
            payload["embeds"] = [res["embed"]]

        try:
            self._api_request("POST", f"/channels/{channel_id}/messages", payload)
        except Exception as e:
            print(f"[NAMELESS DEITY] Erro ao enviar mensagem no canal {channel_id}: {e}", flush=True)

    def run_forever(self) -> None:
        # Tenta primeiro com MESSAGE_CONTENT (33281) e faz fallback automático para Intents
        # não-privilegiados (513) caso o usuário não tenha ativado Message Content no Portal do Discord.
        intents_to_try = [33281, 513]
        intent_idx = 0

        while self.running:
            try:
                gw_Url = "wss://gateway.discord.gg/?v=10&encoding=json"
                ws = _SimpleWebSocket(gw_Url, timeout=45.0)
                self.ws = ws

                op, raw = ws.recv_frame()
                hello = json.loads(raw.decode("utf-8"))
                hb_interval = hello["d"]["heartbeat_interval"] / 1000.0

                current_intents = intents_to_try[intent_idx]
                identify = {
                    "op": 2,
                    "d": {
                        "token": self.token,
                        "intents": current_intents,
                        "properties": {"os": "linux", "browser": "nameless_deity", "device": "nameless_deity"},
                        "presence": {
                            "activities": [{"name": "👁️ A Linha do Tempo (/progresso)", "type": 3}],
                            "status": "online",
                        },
                    },
                }
                ws.send_text(json.dumps(identify))

                stop_hb = threading.Event()

                def _heartbeat_loop() -> None:
                    while not stop_hb.wait(hb_interval):
                        try:
                            ws.send_text(json.dumps({"op": 1, "d": self.seq}))
                        except Exception:
                            break

                hb_thread = threading.Thread(target=_heartbeat_loop, daemon=True)
                hb_thread.start()

                while self.running:
                    opcode, payload_bytes = ws.recv_frame()
                    if opcode == 0x8:
                        close_code = struct.unpack(">H", payload_bytes[:2])[0] if len(payload_bytes) >= 2 else 0
                        if close_code == 4014 and intent_idx == 0:
                            print(
                                "[NAMELESS DEITY] Message Content Intent desativado no Portal Discord; "
                                "reconectando no modo Slash Commands (/progresso, /proximo...)...",
                                flush=True,
                            )
                            intent_idx = 1
                        elif close_code == 4004:
                            print("[NAMELESS DEITY] ❌ DISCORD_BOT_TOKEN inválido! Verifique o arquivo .env.", flush=True)
                            self.running = False
                        break

                    if opcode != 0x1 or not payload_bytes:
                        continue

                    packet = json.loads(payload_bytes.decode("utf-8", errors="replace"))
                    op_type = packet.get("op")
                    if packet.get("s") is not None:
                        self.seq = packet["s"]

                    if op_type == 11:
                        continue
                    if op_type == 1:
                        ws.send_text(json.dumps({"op": 1, "d": self.seq}))
                    elif op_type == 7 or op_type == 9:
                        break
                    elif op_type == 0:
                        t_event = packet.get("t")
                        d_event = packet.get("d") or {}
                        if t_event == "READY":
                            user_obj = d_event.get("user") or {}
                            self.bot_user_id = user_obj.get("id")
                            app_obj = d_event.get("application") or {}
                            self.app_id = app_obj.get("id") or self.bot_user_id
                            print(
                                f"[NAMELESS DEITY] 👁️ Bot '{user_obj.get('username', BOT_NAME)}' conectado ao Discord!",
                                flush=True,
                            )
                            if self.app_id:
                                threading.Thread(
                                    target=self.register_slash_commands,
                                    args=(self.app_id,),
                                    daemon=True,
                                ).start()
                        elif t_event == "INTERACTION_CREATE":
                            threading.Thread(
                                target=self.handle_interaction,
                                args=(d_event,),
                                daemon=True,
                            ).start()
                        elif t_event == "MESSAGE_CREATE":
                            threading.Thread(
                                target=self.handle_message,
                                args=(d_event,),
                                daemon=True,
                            ).start()

                stop_hb.set()
                ws.close()
            except Exception as e:
                print(f"[NAMELESS DEITY] Reconectando Bot Discord em 10s ({e})...", flush=True)
                time.sleep(10)


# ==============================================================================
# 9. DAEMON UNIFICADO (LOG WATCHER + WORLD SYNC + DISCORD BOT)
# ==============================================================================
def run_daemon() -> int:
    print("[NAMELESS DEITY] 👁️ Iniciando Guardião da Progressão Linear (Bosses & Objetivos)...", flush=True)
    sync_from_world_files()

    bot_token = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
    if bot_token:
        bot = NamelessDeityDiscordBot(bot_token)
        bot_thread = threading.Thread(target=bot.run_forever, daemon=True)
        bot_thread.start()
    else:
        print(
            "[NAMELESS DEITY] Dica: DISCORD_BOT_TOKEN vazio no .env (Comandos no chat do jogo !progresso e avisos via Webhook estão ativos).",
            flush=True,
        )

    console_log = os.environ.get("TMOD_CONSOLE_LOG", "/tmp/current_console.log")
    server_log = os.environ.get("TMOD_SERVER_LOG_PATH", "/terraria-server/tModLoader-Logs/server.log")

    last_sizes: Dict[str, int] = {}
    last_world_sync = time.time()

    for path in (console_log, server_log):
        if os.path.exists(path):
            try:
                last_sizes[path] = os.path.getsize(path)
            except Exception:
                last_sizes[path] = 0

    while True:
        time.sleep(1.5)
        for path in (console_log, server_log):
            if not os.path.exists(path):
                continue
            try:
                curr_size = os.path.getsize(path)
                prev_size = last_sizes.get(path, 0)
                if curr_size < prev_size:
                    prev_size = 0
                if curr_size > prev_size:
                    with open(path, "r", encoding="utf-8", errors="ignore") as f:
                        f.seek(prev_size)
                        new_text = f.read()
                        last_sizes[path] = f.tell()
                    for line in new_text.splitlines():
                        process_log_line(line)
            except Exception:
                pass

        # A cada 30s sincroniza silenciosamente com o arquivo .twld (caso o mundo tenha sido salvo)
        if time.time() - last_world_sync >= 30:
            last_world_sync = time.time()
            newly = sync_from_world_files()
            if newly:
                state = load_state()
                for b in newly:
                    embed = build_boss_defeated_embed(b, state)
                    send_to_webhook(embed)


# ==============================================================================
# 10. AUTO-TESTE E INTERFACE DE LINHA DE COMANDO (CLI)
# ==============================================================================
def run_self_test() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as tmpdir:
        os.environ["TMOD_WORLDS_DIR"] = tmpdir
        os.environ["TMOD_WORLDNAME"] = "MundoTeste"
        os.environ["DISCORD_WEBHOOK_URL"] = ""

        # 1. Verifica que o primeiro boss da linha é King Slime
        nxt = get_next_boss()
        assert nxt and nxt["id"] == "king_slime", f"Primeiro boss inesperado: {nxt}"

        # 2. Testa simulação de arquivo .twld (GZip NBT) com King Slime e Desert Scourge derrotados
        # Constrói um NBT Compound raiz contendo downedSlimeKing=1 (byte) e downedDesertScourge=1 (byte)
        nbt_buf = bytearray()
        nbt_buf.append(10)  # TAG_Compound root
        nbt_buf.extend(struct.pack(">H", 4) + b"root")
        # TAG_Byte downedSlimeKing = 1
        nbt_buf.append(1)
        k1 = b"downedSlimeKing"
        nbt_buf.extend(struct.pack(">H", len(k1)) + k1 + struct.pack(">b", 1))
        # TAG_Byte downedDesertScourge = 1
        nbt_buf.append(1)
        k2 = b"downedDesertScourge"
        nbt_buf.extend(struct.pack(">H", len(k2)) + k2 + struct.pack(">b", 1))
        # TAG_End
        nbt_buf.append(0)

        twld_test_path = os.path.join(tmpdir, "MundoTeste.twld")
        with gzip.open(twld_test_path, "wb") as gz:
            gz.write(bytes(nbt_buf))

        newly = sync_from_world_files()
        newly_ids = [b["id"] for b in newly]
        assert "king_slime" in newly_ids and "desert_scourge" in newly_ids, f"Falha ao ler .twld NBT: {newly_ids}"

        # 3. Agora o próximo boss deve ser Eye of Cthulhu
        nxt2 = get_next_boss()
        assert nxt2 and nxt2["id"] == "eye_of_cthulhu", f"Próximo boss deveria ser eye_of_cthulhu, veio: {nxt2}"

        # 4. Testa comando !marcar, !meta e detecção de log
        process_log_line("[12:00:00] Eye of Cthulhu has been defeated!")
        nxt3 = get_next_boss()
        assert nxt3 and nxt3["id"] == "crabulon", f"Após Eye of Cthulhu, próximo deveria ser crabulon, veio: {nxt3}"

        res_mark = handle_text_command("!marcar shimmer", actor="Tester", from_game_chat=False)
        assert res_mark and "CONCLUÍDO" in res_mark["text"], f"Falha ao marcar shimmer: {res_mark}"

        res_goal = handle_text_command("!meta Construir Arena para Exo Mechs", actor="Tester", from_game_chat=False)
        assert res_goal and "Nova meta" in res_goal["text"], f"Falha ao criar meta: {res_goal}"

        print("OK_NAMELESS_DEITY_SELFTEST")
    return 0


def main() -> int:
    action = sys.argv[1].lower() if len(sys.argv) > 1 else "status"
    arg = " ".join(sys.argv[2:]).strip() if len(sys.argv) > 2 else ""

    if action == "daemon":
        return run_daemon()
    if action == "self-test":
        return run_self_test()
    if action == "summary-line":
        print(build_summary_line())
        return 0
    if action == "sync-world":
        newly = sync_from_world_files()
        print(f"[NAMELESS DEITY] Sincronizado com .twld ({len(newly)} novos abates detectados).")
        return 0
    if action in ("status", "progresso"):
        embed = build_progress_embed()
        send_to_webhook(embed)
        print(build_summary_line())
        return 0
    if action in ("next", "proximo"):
        embed = build_next_step_embed()
        send_to_webhook(embed)
        nxt = get_next_boss()
        if nxt:
            print(f"🎯 Próximo Boss: {nxt['name']} | Invocação: {nxt['summon']} | Bioma: {nxt['biome']}")
        else:
            print("🏆 Todos os Bosses da trilha foram derrotados!")
        return 0
    if action == "bosses":
        embed = build_bosses_embed(arg)
        send_to_webhook(embed)
        for f in embed.get("fields", []):
            print(f"\n=== {f['name']} ===\n{f['value']}")
        return 0
    if action in ("objectives", "objetivos"):
        embed = build_objectives_embed()
        send_to_webhook(embed)
        for f in embed.get("fields", []):
            print(f"\n=== {f['name']} ===\n{f['value']}")
        return 0
    if action in ("mark", "marcar"):
        ok, msg, _ = mark_target(arg, completed=True, actor="Painel Admin")
        print(msg)
        if ok:
            send_to_webhook(build_progress_embed(), content=msg)
        return 0 if ok else 1
    if action in ("unmark", "desmarcar"):
        ok, msg, _ = mark_target(arg, completed=False, actor="Painel Admin")
        print(msg)
        if ok:
            send_to_webhook(build_progress_embed(), content=msg)
        return 0 if ok else 1
    if action in ("add-goal", "meta"):
        ok, msg = add_custom_goal(arg, actor="Painel Admin")
        print(msg)
        if ok:
            send_to_webhook(build_objectives_embed(), content=msg)
        return 0 if ok else 1

    res = handle_text_command("!" + action + (" " + arg if arg else ""), actor="Console")
    if res and res.get("text"):
        print(res["text"])
    return 0


if __name__ == "__main__":
    sys.exit(main())

