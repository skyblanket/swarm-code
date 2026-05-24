module Main

import Arthopod

fun main() {
  ok = 0
  total = 0

  if (t_species_list() == 'pass') { ok = ok + 1 } else { print("  cross t_species_list") }
  total = total + 1

  if (t_greet_line() == 'pass') { ok = ok + 1 } else { print("  cross t_greet_line") }
  total = total + 1

  if (t_farewell_line() == 'pass') { ok = ok + 1 } else { print("  cross t_farewell_line") }
  total = total + 1

  if (t_rare_wisdom_line() == 'pass') { ok = ok + 1 } else { print("  cross t_rare_wisdom_line") }
  total = total + 1

  if (t_is_addressed() == 'pass') { ok = ok + 1 } else { print("  cross t_is_addressed") }
  total = total + 1

  if (ok == total) {
    print("  ok arthopod: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(0)
  } else {
    print("  fail arthopod: " ++ to_string(ok) ++ "/" ++ to_string(total))
    sys_exit(1)
  }
}

fun t_species_list() {
  list = Arthopod.species_list()
  if (list_contains(list, "beetle") == 'true' && list_contains(list, "mantis") == 'true') { 'pass' } else { 'fail' }
}

fun t_greet_line() {
  buddy = {'species': "mantis", 'rarity': "common", 'name': "Ziggy", 'personality': "calm"}
  result = Arthopod.greet_line(buddy)
  expected = "Hi, I'm Ziggy — a common mantis. I'll be here while you code."
  if (result == expected) { 'pass' } else { 'fail' }
}

fun t_farewell_line() {
  buddy = {'species': "ant", 'rarity': "uncommon", 'name': "Dot", 'personality': "bold"}
  result = Arthopod.farewell_line(buddy)
  expected = "See you next session. — Dot"
  if (result == expected) { 'pass' } else { 'fail' }
}

fun t_rare_wisdom_line() {
  legendary_buddy = {'species': "dragonfly", 'rarity': "legendary", 'name': "Aureus", 'personality': "mystic"}
  common_buddy = {'species': "beetle", 'rarity': "common", 'name': "Bix", 'personality': "sleepy"}
  leg_result = Arthopod.rare_wisdom_line(legendary_buddy)
  com_result = Arthopod.rare_wisdom_line(common_buddy)
  leg_expected = "(I could show you things no common beetle has ever seen, friend.)"
  com_expected = "(keep going — Bix is watching quietly)"
  if (leg_result == leg_expected && com_result == com_expected) { 'pass' } else { 'fail' }
}

fun t_is_addressed() {
  buddy = {'species': "bee", 'rarity': "rare", 'name': "Buzz", 'personality': "chatty"}
  by_name = Arthopod.is_addressed("Hey Buzz, how are you?", buddy)
  by_arthopod = Arthopod.is_addressed("arthopod help me", buddy)
  not_addressed = Arthopod.is_addressed("just some code", buddy)
  if (by_name == 'true' && by_arthopod == 'true' && not_addressed == 'false') { 'pass' } else { 'fail' }
}
