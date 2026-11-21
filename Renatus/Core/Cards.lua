-- Core/Cards.lua: the fixed "Azeroth" card set, the same for every player.
-- It gives the album something to collect from day one; the guild series
-- (Core/Album.lua) are generated from what the guild lives.
--
-- Each card lists candidate icons, best first: the first one present on the
-- client is used (UI.CardArt), the last one is a safe generic icon.
local _, ns = ...

local Cards = {}
ns.Cards = Cards

Cards.SERIES = {
    { key = "est", label = "Royaumes de l'Est" },
    { key = "kalimdor", label = "Kalimdor" },
    { key = "donjons", label = "Donjons et raids" },
    { key = "personnages", label = "Personnages" },
    { key = "heros", label = "Classes et races" },
    { key = "bestiaire", label = "Bestiaire" },
    { key = "tresors", label = "Trésors et curiosités" },
}

local list = {}
Cards.LIST = list

local function add(series, key, rarity, name, icons, flavor, extra)
    local c = { id = "AZ:" .. series .. ":" .. key, series = series, rarity = rarity, name = name,
        icons = icons, flavor = flavor, azeroth = true }
    if extra then for k, v in pairs(extra) do c[k] = v end end
    table.insert(list, c)
end

-- Zone icons: the exploration achievement icon (with or without _01), then a map.
local function zone(series, key, rarity, name, icon, flavor)
    add(series, key, rarity, name, { "Achievement_Zone_" .. icon, "Achievement_Zone_" .. icon .. "_01", "INV_Misc_Map_01" }, flavor)
end

------------------------------------------------------------------------
-- Royaumes de l'Est
------------------------------------------------------------------------
zone("est", "elwynn", "common", "Forêt d'Elwynn", "ElwynnForest", "Des loups, des kobolds, et un gnoll qui terrorise toute une région. Bienvenue.")
zone("est", "dunmorogh", "common", "Dun Morogh", "DunMorogh", "Il neige, la bière est chaude et les trogg n'ont aucune conversation.")
zone("est", "tirisfal", "common", "Clairières de Tirisfal", "TirisfalGlades", "Le meilleur endroit pour se réveiller mort. Ambiance garantie.")
zone("est", "marche", "common", "Marche de l'Ouest", "Westfall", "Des champs, des épouvantails, et un complot dans une mine. Comme chez soi.")
zone("est", "lochmodan", "common", "Loch Modan", "LochModan", "Un barrage, un lac et des nains qui pêchent. Personne ne sait quoi.")
zone("est", "pinsargentes", "common", "Forêt des Pins-Argentés", "Silverpine", "Des worgens dans les bois. Le guide touristique en parle peu.")
zone("est", "carmines", "common", "Les Carmines", "RedridgeMountains", "Les gnolls y ont des drapeaux. La garde y a des affiches « Recherché ».")
zone("est", "penombre", "uncommon", "Bois de la Pénombre", "Duskwood", "Il y fait toujours nuit. Les habitants disent que c'est une question d'habitude.")
zone("est", "paluns", "uncommon", "Les Paluns", "Wetlands", "Humide, boueux, plein de crocilisques. Le paradis des cordonniers.")
zone("est", "hautebrande", "uncommon", "Contreforts de Hautebrande", "HillsbradFoothills", "Champ de bataille permanent entre deux villages qui se détestent poliment.")
zone("est", "alterac", "uncommon", "Montagnes d'Alterac", "AlteracMountains", "Des ogres, des orcs, un royaume déchu. Et du vent. Surtout du vent.")
zone("est", "arathi", "uncommon", "Hautes-terres d'Arathi", "ArathiHighlands", "Le berceau de l'humanité, désormais réputé pour ses fermes très disputées.")
zone("est", "strangleronce", "rare", "Vallée de Strangleronce", "Stranglethorn", "Panthères, tigres, raptors, pirates. Et un pêcheur nommé Nat qui s'en moque.")
zone("est", "ingrates", "uncommon", "Terres ingrates", "Badlands", "Le nom dit tout. Les dragons noirs, eux, n'ont pas lu la pancarte.")
zone("est", "chagrins", "uncommon", "Marais des Chagrins", "SwampSorrows", "On y vient pour un temple englouti. On y reste pour les moustiques.")
zone("est", "hinterlands", "rare", "Les Hinterlands", "Hinterlands", "Trolls sauvages, griffons nobles, nains lointains. Prévoir des bottes.")
zone("est", "ventsbrules", "rare", "Gorge des Vents brûlants", "SearingGorge", "Il fait chaud. Très chaud. Les nains Sombrefer trouvent ça agréable.")
zone("est", "steppes", "rare", "Steppes ardentes", "BurningSteppes", "Tout brûle, depuis longtemps. Personne n'a pensé à éteindre.")
zone("est", "foudroyees", "rare", "Terres foudroyées", "BlastedLands", "Un portail des ténèbres, des démons, et une vue imprenable sur rien.")
zone("est", "maleterresouest", "rare", "Maleterres de l'Ouest", "WesternPlaguelands", "Les champs y poussent mal. Les morts-vivants, en revanche, très bien.")
zone("est", "maleterresest", "epic", "Maleterres de l'Est", "EasternPlaguelands", "Le Fléau y a ses habitudes. La Croisade aussi. Les deux sont insupportables.")
zone("est", "deuillevent", "epic", "Défilé de Deuillevent", "DeadwindPass", "Silence, corbeaux et la tour d'un mage. On n'entre pas sans y être invité.")

------------------------------------------------------------------------
-- Kalimdor
------------------------------------------------------------------------
zone("kalimdor", "durotar", "common", "Durotar", "Durotar", "Rouge, sec, plein de scorpions. Les orcs l'ont choisi exprès.")
zone("kalimdor", "mulgore", "common", "Mulgore", "Mulgore", "Des plaines à perte de vue et des kodos qui ne demandent rien à personne.")
zone("kalimdor", "teldrassil", "common", "Teldrassil", "Teldrassil", "Un arbre. Très grand. On y vit dedans et on s'y perd souvent.")
zone("kalimdor", "tarides", "common", "Les Tarides", "Barrens", "Où est la femme de Mankrik ? Le canal général cherche encore.")
zone("kalimdor", "sombrivage", "common", "Sombrivage", "Darkshore", "Une longue plage, des naufrages, et des murlocs qui ont tout vu.")
zone("kalimdor", "orneval", "uncommon", "Orneval", "Ashenvale", "Une forêt sacrée que tout le monde veut abattre. Sauf ceux qui y vivent.")
zone("kalimdor", "serresrocheuses", "uncommon", "Serres-Rocheuses", "StonetalonMountains", "Des falaises, des harpies, et une compagnie minière sans scrupules.")
zone("kalimdor", "millepointes", "uncommon", "Mille pointes", "ThousandNeedles", "Des pitons rocheux et une course de gobelins. Personne ne gagne.")
zone("kalimdor", "desolace", "uncommon", "Désolace", "Desolace", "Le nom n'est pas une erreur de traduction. C'est une description.")
zone("kalimdor", "aprefange", "uncommon", "Marécage d'Âprefange", "DustwallowMarsh", "Une dragonne s'y cache, paraît-il. Les moustiques, eux, ne se cachent pas.")
zone("kalimdor", "feralas", "rare", "Feralas", "Feralas", "Forêt immense, géants errants, et des elfes qui n'auraient jamais dû rester.")
zone("kalimdor", "tanaris", "rare", "Tanaris", "Tanaris", "Du sable, des gobelins, du sable, des pirates, et encore du sable.")
zone("kalimdor", "azshara", "rare", "Azshara", "Azshara", "Des ruines d'une beauté triste. Le genre d'endroit qu'on visite une fois.")
zone("kalimdor", "gangrebois", "rare", "Gangrebois", "Felwood", "La forêt a mal tourné. Ne mangez rien de ce qui y pousse.")
zone("kalimdor", "ungoro", "rare", "Cratère d'Un'Goro", "UnGoroCrater", "Dinosaures géants, cristaux magiques, et un singe qui veut des œufs.")
zone("kalimdor", "berceau", "epic", "Berceau-de-l'Hiver", "Winterspring", "Neige éternelle, ours hostiles et un yéti qui collectionne les rumeurs.")
zone("kalimdor", "silithus", "epic", "Silithus", "Silithus", "Des insectes gros comme des maisons. Ils ont un plan. C'est inquiétant.")
zone("kalimdor", "reflet", "rare", "Reflet-de-Lune", "Moonglade", "Le seul endroit où les druides acceptent de dormir. Les autres sont priés de chuchoter.")

------------------------------------------------------------------------
-- Donjons et raids (one card per iconic boss)
------------------------------------------------------------------------
local function boss(key, rarity, name, icon, flavor, extra)
    add("donjons", key, rarity, name, { "Achievement_Boss_" .. icon, "INV_Misc_Head_Dragon_01" }, flavor, extra)
end
boss("vancleef", "uncommon", "Edwin VanCleef", "EdwinVancleef", "Les Mortemines. Il avait un bateau, un plan et une rancune. Il lui manquait un ami.")
boss("thredd", "common", "Bazil Thredd", "Bazil_Thredd", "La Prison. Il a organisé l'émeute. Il n'avait pas prévu les aventuriers.")
boss("mutanus", "uncommon", "Mutanus le Dévoreur", "Mutanus_the_Devourer", "Cavernes des Lamentations. Il dévore. Il a un nom qui le dit.")
boss("arugal", "uncommon", "Archimage Arugal", "Archmage_Arugal", "Donjon d'Ombrecroc. « Vous êtes mes enfants. » Ils n'avaient rien demandé.")
boss("thermaplugg", "rare", "Mekgénieur Thermojoncteur", "Mekgineer_Thermaplugg", "Gnomeregan. Il a irradié une ville pour une erreur de calcul. Par principe.")
boss("charlga", "uncommon", "Charlga Trancheflanc", "Charlga_Razorflank", "Kraal de Tranchebauge. Matriarche, sorcière, et très attachée à sa ronce.")
boss("amnennar", "uncommon", "Amnennar le Porte-froid", "Amnennar_the_Coldbringer", "Souilles de Tranchebauge. Une liche chez les sangliers. Personne n'a d'explication.")
boss("whitemane", "rare", "Haute-inquisitrice Blanchetête", "HighInquisitor_Whitemane", "Monastère écarlate. Elle ressuscite le commandant. Tuez-la d'abord.")
boss("archaedas", "rare", "Archaedas", "Archaedas", "Uldaman. Un gardien titan réveillé par des pillards. Il est de mauvaise humeur.")
boss("theradras", "rare", "Princesse Theradras", "Princess_Theradras", "Maraudon. Une princesse de la terre. Pas le genre à attendre un prince.")
boss("ukorz", "rare", "Chef Ukorz Scalpessable", "ChiefUkorzSandscalp", "Zul'Farrak. Ses trolls tiennent des escaliers. Il compte sur eux.")
boss("eranikus", "rare", "Ombre d'Eranikus", "ShadeOfEranikus", "Temple d'Atal'Hakkar. Un dragon prisonnier d'un cauchemar. Le temple aussi.")
boss("thaurissan", "epic", "Empereur Dagran Thaurissan", "EmperorDagranThaurissan", "Profondeurs de Rochenoire. Il a épousé une princesse. Le roi Magni n'a pas apprécié.")
boss("drakkisath", "epic", "Général Drakkisath", "GeneralDrakkisath", "Pic de Rochenoire. Il garde une marque dont tout le monde a besoin pour une clé.")
boss("rivendare", "epic", "Baron Rivendare", "Baron_Rivendare", "Stratholme. Son destrier tombe une fois sur cent. Revenez demain.", { icons = { "Achievement_Boss_Baron_Rivendare", "Ability_Mount_Undeadhorse", "INV_Misc_Head_Dragon_01" } })
boss("gandling", "epic", "Sombre maître Gandling", "DarkmasterGandling", "Scholomance. Directeur d'école. Les élèves ne passent pas en classe supérieure.")
boss("onyxia", "epic", "Onyxia", "Onyxia", "« Encore des respirations profondes ? » Un raid, quarante personnes, une dragonne qui s'envole.")
boss("hakkar", "epic", "Hakkar l'Écorcheur d'âmes", "Hakkar", "Zul'Gurub. Un dieu du sang. Les familiers de vos amis ont emporté sa malédiction en ville.")
boss("nefarian", "epic", "Nefarian", "Nefarion", "Repaire de l'Aile noire. Il transforme les classes en catastrophes. Une à la fois.")
boss("ragnaros", "legendary", "Ragnaros", "Ragnaros", "« TROP TÔT ! » Cœur du Magma. Le seigneur du feu n'aime pas qu'on le réveille.")
boss("cthun", "legendary", "C'Thun", "CThun", "Ahn'Qiraj. Un œil, des tentacules, et l'inébranlable certitude que vous allez mourir.")
boss("kelthuzad", "legendary", "Kel'Thuzad", "KelThuzad_01", "Naxxramas. Une nécropole volante. Il attend au dernier étage, bien au frais.")

------------------------------------------------------------------------
-- Personnages
------------------------------------------------------------------------
add("personnages", "lardeur", "legendary", "Lardeur", { "INV_Misc_Head_Gnoll_01", "Ability_Hunter_Pet_Hyena" },
    "Le gnoll qui a fait trembler Elwynn. Des générations de héros niveau 11 s'en souviennent.")
add("personnages", "mankrik", "rare", "La femme de Mankrik", { "INV_Misc_Bone_HumanSkull_01" },
    "Elle a été cherchée par plus d'aventuriers que n'importe quel trésor d'Azeroth.")
add("personnages", "leeroy", "legendary", "Leeroy Jenkins", { "Ability_Warrior_BattleShout", "INV_Misc_Food_15" },
    "« Bon, les gars, c'est parti ! » Il avait du poulet. Il avait un plan, aussi, mais pas le même.")
add("personnages", "thrall", "epic", "Thrall", { "Achievement_Leader_ThrallIcon", "Achievement_Leader_Thrall", "Spell_Nature_BloodLust" },
    "Chef de guerre de la Horde. Ancien gladiateur, chaman, et propriétaire d'un marteau célèbre.")
add("personnages", "jaina", "epic", "Jaina Portvaillant", { "Achievement_Leader_Jaina_Proudmoore", "Spell_Frost_FrostBolt02" },
    "Dame de Theramore. Elle croit encore à la paix. Garder un œil sur elle.")
add("personnages", "sylvanas", "epic", "Sylvanas Coursevent", { "Achievement_Leader_Sylvanas", "Spell_Shadow_RaiseDead" },
    "Dame noire des Réprouvés. Elle tire juste et ne pardonne rien.")
add("personnages", "magni", "rare", "Magni Barbe-de-bronze", { "Achievement_Leader_King_Magni_Bronzebeard", "INV_Hammer_04" },
    "Roi de Forgefer. Grand cœur, longue barbe, très mauvaise opinion des Sombrefer.")
add("personnages", "cairne", "rare", "Cairne Sabot-de-Sang", { "Achievement_Leader_Cairne Bloodhoof", "Achievement_Character_Tauren_Male" },
    "Chef des Taurens. Sage, patient, et deux fois plus grand que vous.")
add("personnages", "tyrande", "rare", "Tyrande Murmevent", { "Achievement_Leader_Tyrande_Whisperwind", "Spell_Holy_ElunesGrace" },
    "Grande prêtresse d'Élune. Dix mille ans d'expérience. Elle a vu passer vos ancêtres.")
add("personnages", "voljin", "rare", "Vol'jin", { "Achievement_Leader_VolJin", "Achievement_Character_Troll_Male" },
    "Chef des Sombrelances. Il a des esprits pour conseillers et des Échos pour voisins.")
add("personnages", "bolvar", "rare", "Bolvar Fordragon", { "Achievement_Leader_King_Varian_Wrynn", "Spell_Holy_HolyBolt" },
    "Régent de Hurlevent pendant que le roi a disparu. Il fait de son mieux. On le sent.")
add("personnages", "nat", "uncommon", "Nat Pagle", { "INV_Fishingpole_02", "INV_Misc_Fish_02" },
    "Le plus grand pêcheur d'Azeroth. Le monde brûle ; Nat surveille son bouchon.")
add("personnages", "dughan", "common", "Maréchal Dughan", { "INV_Misc_Note_01" },
    "Il distribue des quêtes à Comté-de-l'Or depuis toujours. Il ne bouge jamais. Jamais.")

------------------------------------------------------------------------
-- Classes et races (class cards use the class icon)
------------------------------------------------------------------------
local CLASSES = {
    { "WARRIOR", "Guerrier", "Il tape. Si ça ne marche pas, il tape plus fort. C'est une philosophie." },
    { "PALADIN", "Paladin", "La Lumière est avec lui. Sa bulle aussi, quand ça tourne mal." },
    { "HUNTER", "Chasseur", "Son familier fait la moitié du travail et prend tout le mérite." },
    { "ROGUE", "Voleur", "Vous ne l'avez pas vu. C'était le but. Votre bourse non plus." },
    { "PRIEST", "Prêtre", "Il soigne vos erreurs et vous rappelle chacune d'elles." },
    { "SHAMAN", "Chaman", "Quatre totems, quatre éléments et un seul « je peux le poser où ? »." },
    { "MAGE", "Mage", "Eau, pain, portails : l'aubergiste du groupe, version explosive." },
    { "WARLOCK", "Démoniste", "Il a un démon de compagnie et collectionne les éclats d'âme." },
    { "DRUID", "Druide", "Ours, chat, arbre ou phoque : il est tout, sauf à l'heure." },
}
for _, cl in ipairs(CLASSES) do
    add("heros", "classe_" .. cl[1]:lower(), "common", cl[2], {}, cl[3], { class = cl[1] })
end
local RACES = {
    { "humain", "Humains", "Human", "Ils ont des châteaux, des rois et un goût certain pour les ennuis." },
    { "nain", "Nains", "Dwarf", "Barbe, bière, archéologie. Dans un ordre qui varie selon l'heure." },
    { "gnome", "Gnomes", "Gnome", "Petits, brillants, et responsables d'une catastrophe nucléaire assez récente." },
    { "elfedelanuit", "Elfes de la nuit", "Nightelf", "Dix mille ans d'histoire et toujours le premier à sauter dans le vide." },
    { "orc", "Orcs", "Orc", "Lok'tar ogar ! Ils ont changé. Ils le rappellent souvent." },
    { "troll", "Trolls", "Troll", "Détendus, grands, régénérants. Ils te diront de rester tranquille, mon frère." },
    { "tauren", "Taurens", "Tauren", "Paisibles jusqu'à la charge. La charge est rarement paisible." },
    { "reprouve", "Réprouvés", "Undead", "Morts, libres et sarcastiques. Il leur manque parfois une mâchoire." },
}
for _, r in ipairs(RACES) do
    add("heros", "race_" .. r[1], "uncommon", r[2],
        { "Achievement_Character_" .. r[3] .. "_Male", "Achievement_Character_" .. r[3] .. "_Female", "INV_Misc_GroupNeedMore" }, r[4])
end

------------------------------------------------------------------------
-- Bestiaire
------------------------------------------------------------------------
local function beast(key, rarity, name, icons, flavor) add("bestiaire", key, rarity, name, icons, flavor) end
beast("murloc", "common", "Murloc", { "INV_Misc_Head_Murloc_01" }, "« Mrglglglgl ! » Seul, inoffensif. En groupe, une légende urbaine.")
beast("kobold", "common", "Kobold", { "INV_Misc_Head_Kobold_01", "Spell_Fire_Fire" }, "« Vous ne prendrez pas la bougie ! » Il y tient vraiment, à sa bougie.")
beast("defias", "common", "Bandit défias", { "INV_Misc_Bandana_03", "Ability_Rogue_Disguise" }, "Bandeau rouge, mauvaises intentions. Toujours trois quand on en voit un.")
beast("gnoll", "common", "Gnoll", { "INV_Misc_Head_Gnoll_01", "Ability_Hunter_Pet_Hyena" }, "Ils viennent en meute, crient très fort et lâchent des oreilles de gnoll.")
beast("loup", "common", "Loup des bois", { "Ability_Hunter_Pet_Wolf" }, "Les premières victimes de tout aventurier. Ils ne l'ont jamais accepté.")
beast("araignee", "common", "Araignée de la Pénombre", { "Ability_Hunter_Pet_Spider" }, "Huit pattes, huit yeux, zéro amis. Elle vous attendait.")
beast("ours", "common", "Ours grizzly", { "Ability_Hunter_Pet_Bear" }, "Il était là avant vous. Il le sera après. Il ne cherche pas la discussion.")
beast("haut-trotteur", "common", "Haut-trotteur", { "Ability_Hunter_Pet_TallStrider" }, "Un oiseau sur des échasses. Il ne vole pas, il juge.")
beast("crocilisque", "uncommon", "Crocilisque", { "Ability_Hunter_Pet_Crocolisk" }, "Viande de crocilisque, recette de base. Le crocilisque ne partage pas cet avis.")
beast("raptor", "uncommon", "Raptor", { "Ability_Hunter_Pet_Raptor" }, "Rapide, affamé, et toujours en groupe derrière le rocher que vous n'avez pas vérifié.")
beast("harpie", "uncommon", "Harpie", { "Ability_Hunter_Pet_Owl", "INV_Feather_04" }, "Elle crie, elle griffe, elle vole. Elle vole surtout vos affaires.")
beast("centaure", "uncommon", "Centaure", { "Ability_Mount_Kodo_01", "INV_Misc_Horn_01" }, "Moitié cheval, moitié guerrier, entièrement hostile.")
beast("mouton", "rare", "Mouton", { "Spell_Nature_Polymorph" }, "Il était votre tank il y a une seconde. Le mage dit que c'était un accident.")
beast("diablosaure", "rare", "Diablosaure", { "Ability_Hunter_Pet_Devilsaur", "Ability_Hunter_Pet_Raptor" }, "Un'Goro. Le sol tremble, les chasseurs se cachent, le cuir se vend cher.")
beast("elementaire", "rare", "Élémentaire de feu", { "Spell_Fire_Elemental_Totem", "Spell_Fire_Fire" }, "Il brûle. Il ne s'arrête pas de brûler. Il aimerait parfois.")
beast("goule", "uncommon", "Goule", { "Spell_Shadow_RaiseDead" }, "Elle a faim, elle est lente, et elle a des amis dans le cimetière d'à côté.")

------------------------------------------------------------------------
-- Trésors et curiosités
------------------------------------------------------------------------
local function item(key, rarity, name, icons, flavor) add("tresors", key, rarity, name, icons, flavor) end
item("foyer", "common", "Pierre de foyer", { "INV_Misc_Rune_01" }, "Votre foyer est fixé à l'auberge. Depuis trois ans. Vous n'avez jamais dormi là.")
item("lin", "common", "Étoffe de lin", { "INV_Fabric_Linen_01" }, "La monnaie officieuse des débutants. Les tailleurs en rêvent la nuit.")
item("potion", "common", "Potion de soins", { "INV_Potion_51", "INV_Potion_54" }, "Goût de cerise et de regret. Toujours bue une seconde trop tard.")
item("pain", "common", "Pain de mage", { "INV_Misc_Food_11", "INV_Misc_Food_15" }, "Gratuit, nourrissant, et réclamé à chaque arrêt du groupe.")
item("piece", "common", "Pièce d'or", { "INV_Misc_Coin_01" }, "Pour la réparation, le dresseur, la monture. Jamais assez.")
item("tabard", "uncommon", "Tabard de guilde", { "INV_Shirt_GuildTabard_01" }, "Dix pièces d'or de dessin, des heures de débat, un écusson discutable.")
item("sac", "uncommon", "Sac de seize places", { "INV_Misc_Bag_10" }, "Le vrai luxe d'un aventurier. Plein en un quart d'heure.")
item("cle", "uncommon", "Clé squelette", { "INV_Misc_Key_11", "INV_Misc_Key_03" }, "Ouvre les portes de Scholomance. Pas celles de l'auberge, hélas.")
item("canne", "uncommon", "Canne à pêche", { "INV_Fishingpole_02" }, "Elle ne prend jamais le poisson que vous cherchez. Toujours celui de la quête d'à côté.")
item("cheval", "rare", "Rênes de cheval de guerre", { "Ability_Mount_RidingHorse" }, "Cent pièces d'or. Toute une vie d'économies, pour aller un peu plus vite.")
item("destrier", "epic", "Rênes du destrier de la mort", { "Ability_Mount_Undeadhorse" }, "Le baron le lâche une fois sur cent. La guilde en parle encore.")
item("sulfuras", "legendary", "Sulfuras, Main de Ragnaros", { "INV_Hammer_Unique_Sulfuras", "Spell_Fire_Fire" }, "Un marteau en flammes, arraché au seigneur du feu. Il chauffe un peu la main.")
item("thunderfury", "legendary", "Lame-tonnerre", { "INV_Sword_39" }, "« Vous avez entendu parler de Lame-tonnerre, lame bénie du Cherchevent ? » Tout le monde.")
item("atiesh", "legendary", "Atiesh, Grand bâton du Gardien", { "INV_Staff_Medivh", "INV_Staff_13" }, "Le bâton de Medivh. Quarante éclats, un portail, et beaucoup d'ennemis jaloux.")
item("murlocfin", "rare", "Costume de murloc", { "INV_Misc_Head_Murloc_01" }, "Pour se fondre dans la foule à Sombrivage. « Mrglgl. »")

-- 3D models (UI/TabAlbum.lua): creature ids, only those known for sure. A creature the
-- client cannot show leaves the icon in place.
local NPC = {
    ["donjons:vancleef"] = 639, ["donjons:thredd"] = 1716, ["donjons:mutanus"] = 3654, ["donjons:arugal"] = 4275,
    ["donjons:thermaplugg"] = 7800, ["donjons:charlga"] = 4421, ["donjons:amnennar"] = 7358,
    ["donjons:whitemane"] = 3977, ["donjons:archaedas"] = 2748, ["donjons:theradras"] = 12201,
    ["donjons:ukorz"] = 7267, ["donjons:eranikus"] = 5709, ["donjons:thaurissan"] = 9019,
    ["donjons:drakkisath"] = 10363, ["donjons:rivendare"] = 10440, ["donjons:gandling"] = 1853,
    ["donjons:onyxia"] = 10184, ["donjons:hakkar"] = 14834, ["donjons:nefarian"] = 11583,
    ["donjons:ragnaros"] = 11502, ["donjons:cthun"] = 15727, ["donjons:kelthuzad"] = 15990,
    ["personnages:lardeur"] = 448, ["personnages:thrall"] = 4949, ["personnages:jaina"] = 4968,
    ["personnages:sylvanas"] = 10181, ["personnages:magni"] = 2784, ["personnages:cairne"] = 3057,
    ["personnages:tyrande"] = 7999, ["personnages:voljin"] = 10540, ["personnages:bolvar"] = 1748,
    ["personnages:nat"] = 12919, ["personnages:dughan"] = 240,
    ["bestiaire:murloc"] = 515, ["bestiaire:kobold"] = 6, ["bestiaire:defias"] = 116,
}
-- Beasts without a named creature: a well-known one of the kind.
NPC["bestiaire:gnoll"] = 117        -- Riverpaw Gnoll
NPC["bestiaire:loup"] = 69          -- Timber Wolf
NPC["bestiaire:mouton"] = 1933      -- Sheep
NPC["bestiaire:diablosaure"] = 6498 -- Devilsaur
-- Force / endurance of the creatures, and the bonus (+force / +endurance) of the items.
-- Places carry none. The guild cards get theirs from the AI, or Album.DefaultStats.
local STATS = {
    -- dungeon and raid bosses
    ["donjons:vancleef"] = { 4, 3 }, ["donjons:thredd"] = { 2, 2 }, ["donjons:mutanus"] = { 3, 4 },
    ["donjons:arugal"] = { 4, 3 }, ["donjons:thermaplugg"] = { 5, 4 }, ["donjons:charlga"] = { 4, 4 },
    ["donjons:amnennar"] = { 5, 4 }, ["donjons:whitemane"] = { 4, 5 }, ["donjons:archaedas"] = { 4, 7 },
    ["donjons:theradras"] = { 5, 6 }, ["donjons:ukorz"] = { 5, 4 }, ["donjons:eranikus"] = { 6, 5 },
    ["donjons:thaurissan"] = { 7, 6 }, ["donjons:drakkisath"] = { 7, 7 }, ["donjons:rivendare"] = { 7, 6 },
    ["donjons:gandling"] = { 6, 5 }, ["donjons:onyxia"] = { 8, 8 }, ["donjons:hakkar"] = { 8, 7 },
    ["donjons:nefarian"] = { 9, 8 }, ["donjons:ragnaros"] = { 11, 10 }, ["donjons:cthun"] = { 10, 12 },
    ["donjons:kelthuzad"] = { 11, 9 },
    -- characters
    ["personnages:lardeur"] = { 9, 6 }, ["personnages:mankrik"] = { 0, 1 }, ["personnages:leeroy"] = { 10, 2 },
    ["personnages:thrall"] = { 8, 7 }, ["personnages:jaina"] = { 8, 5 }, ["personnages:sylvanas"] = { 8, 5 },
    ["personnages:magni"] = { 6, 7 }, ["personnages:cairne"] = { 6, 8 }, ["personnages:tyrande"] = { 6, 6 },
    ["personnages:voljin"] = { 6, 5 }, ["personnages:bolvar"] = { 5, 7 }, ["personnages:nat"] = { 1, 3 },
    ["personnages:dughan"] = { 1, 1 },
    -- classes and races
    ["heros:classe_warrior"] = { 3, 4 }, ["heros:classe_paladin"] = { 2, 5 }, ["heros:classe_hunter"] = { 3, 3 },
    ["heros:classe_rogue"] = { 4, 2 }, ["heros:classe_priest"] = { 1, 3 }, ["heros:classe_shaman"] = { 3, 3 },
    ["heros:classe_mage"] = { 5, 1 }, ["heros:classe_warlock"] = { 4, 2 }, ["heros:classe_druid"] = { 3, 3 },
    ["heros:race_humain"] = { 3, 3 }, ["heros:race_nain"] = { 3, 4 }, ["heros:race_gnome"] = { 2, 2 },
    ["heros:race_elfedelanuit"] = { 3, 3 }, ["heros:race_orc"] = { 4, 3 }, ["heros:race_troll"] = { 3, 3 },
    ["heros:race_tauren"] = { 3, 5 }, ["heros:race_reprouve"] = { 3, 3 },
    -- bestiary
    ["bestiaire:murloc"] = { 1, 1 }, ["bestiaire:kobold"] = { 1, 2 }, ["bestiaire:defias"] = { 2, 2 },
    ["bestiaire:gnoll"] = { 2, 2 }, ["bestiaire:loup"] = { 2, 1 }, ["bestiaire:araignee"] = { 2, 1 },
    ["bestiaire:ours"] = { 2, 4 }, ["bestiaire:haut-trotteur"] = { 1, 2 }, ["bestiaire:crocilisque"] = { 3, 3 },
    ["bestiaire:raptor"] = { 4, 2 }, ["bestiaire:harpie"] = { 3, 2 }, ["bestiaire:centaure"] = { 3, 4 },
    ["bestiaire:mouton"] = { 0, 1 }, ["bestiaire:diablosaure"] = { 7, 6 }, ["bestiaire:elementaire"] = { 5, 3 },
    ["bestiaire:goule"] = { 2, 3 },
    -- items: bonus given to the one who carries them
    ["tresors:foyer"] = { 0, 0 }, ["tresors:lin"] = { 0, 0 }, ["tresors:potion"] = { 0, 2 },
    ["tresors:pain"] = { 0, 1 }, ["tresors:piece"] = { 0, 0 }, ["tresors:tabard"] = { 0, 1 },
    ["tresors:sac"] = { 0, 0 }, ["tresors:cle"] = { 0, 0 }, ["tresors:canne"] = { 0, 0 },
    ["tresors:cheval"] = { 0, 1 }, ["tresors:destrier"] = { 1, 1 }, ["tresors:sulfuras"] = { 5, 2 },
    ["tresors:thunderfury"] = { 5, 1 }, ["tresors:atiesh"] = { 4, 2 }, ["tresors:murlocfin"] = { 0, 0 },
}

for _, c in ipairs(list) do
    local key = c.id:gsub("^AZ:", "")
    c.npc = NPC[key]
    local st = STATS[key]
    if st then c.fo, c.en, c.item = st[1], st[2], c.series == "tresors" or nil end
end

-- Zones: folder of their world map (Interface\WorldMap\<name>\<name>1..12), drawn as
-- full art on the card instead of the medallion.
Cards.MAPS = {
    elwynn = "Elwynn", dunmorogh = "DunMorogh", tirisfal = "Tirisfal", marche = "Westfall",
    lochmodan = "LochModan", pinsargentes = "Silverpine", carmines = "Redridge", penombre = "Duskwood",
    paluns = "Wetlands", hautebrande = "Hilsbrad", alterac = "Alterac", arathi = "Arathi",
    strangleronce = "Stranglethorn", ingrates = "Badlands", chagrins = "SwampOfSorrows",
    hinterlands = "Hinterlands", ventsbrules = "SearingGorge", steppes = "BurningSteppes",
    foudroyees = "BlastedLands", maleterresouest = "WesternPlaguelands", maleterresest = "EasternPlaguelands",
    deuillevent = "DeadwindPass",
    durotar = "Durotar", mulgore = "Mulgore", teldrassil = "Teldrassil", tarides = "Barrens",
    sombrivage = "Darkshore", orneval = "Ashenvale", serresrocheuses = "StonetalonMountains",
    millepointes = "ThousandNeedles", desolace = "Desolace", aprefange = "Dustwallow", feralas = "Feralas",
    tanaris = "Tanaris", azshara = "Aszhara", gangrebois = "Felwood", ungoro = "UngoroCrater",
    berceau = "Winterspring", silithus = "Silithus", reflet = "Moonglade",
}
-- uiMapID of each zone (Classic), for the parts of the map the player has explored.
Cards.MAP_IDS = {
    durotar = 1411, mulgore = 1412, tarides = 1413, alterac = 1416, arathi = 1417, ingrates = 1418,
    foudroyees = 1419, tirisfal = 1420, pinsargentes = 1421, maleterresouest = 1422, maleterresest = 1423,
    hautebrande = 1424, hinterlands = 1425, dunmorogh = 1426, ventsbrules = 1427, steppes = 1428,
    elwynn = 1429, deuillevent = 1430, penombre = 1431, lochmodan = 1432, carmines = 1433,
    strangleronce = 1434, chagrins = 1435, marche = 1436, paluns = 1437, teldrassil = 1438,
    sombrivage = 1439, orneval = 1440, millepointes = 1441, serresrocheuses = 1442, desolace = 1443,
    feralas = 1444, aprefange = 1445, tanaris = 1446, azshara = 1447, gangrebois = 1448, ungoro = 1449,
    reflet = 1450, silithus = 1451, berceau = 1452,
}
-- Map folder and uiMapID of a zone card, nil for the other cards.
function Cards.MapOf(card)
    local series, key = tostring(card.id or ""):match("^AZ:(%a+):(.+)$")
    if series ~= "est" and series ~= "kalimdor" then return nil end
    return Cards.MAPS[key], Cards.MAP_IDS[key]
end

-- Base set: numbered in list order (B-001...), published with v0.10.0.
Cards.BASE_DATE = 1795089600   -- 19/11/2026
for i, c in ipairs(list) do
    c.no, c.t = ("B-%03d"):format(i), Cards.BASE_DATE
end
