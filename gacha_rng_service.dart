import 'dart:math';
import 'package:hive_flutter/hive_flutter.dart';
import '../data/character_database.dart';
import '../models/character.dart';

class GachaRngService {
  // =========================================================================
  // 1. HÀM CHUYỂN ĐỔI: TỪ DATABASE SANG KHUÔN ĐÚC GACHA
  // =========================================================================
  static GachaCharacter _fromDatabase(Map<String, dynamic> data) {
    return GachaCharacter(
      id: data['id'],
      name: data['name'],
      rank: data['rank'],
      baseCp: data['baseCp'],
      personalityTags: List<String>.from(data['personalityTags']),
      isAnimated: data['isAnimated'],
      borderImageUrl: data['borderImageUrl'],
      ringtoneFile: data['ringtoneFile'],
      isUnlocked: data['rank'] != 'SR++',
      shardCount: 1,
    );
  }

  // =========================================================================
  // 2. TỰ ĐỘNG PHÂN LOẠI HỒ CHỨA TỪ CATALOG
  // =========================================================================
  static List<GachaCharacter> get _rollablePool {
    return CharacterDatabase.allCharacters
        .where((c) => c['isGachaDrop'] == true)
        .map((c) => _fromDatabase(c))
        .toList();
  }

  static List<GachaCharacter> get _hiddenPool {
    return CharacterDatabase.allCharacters
        .where((c) => c['isGachaDrop'] == false)
        .map((c) => _fromDatabase(c))
        .toList();
  }

  static List<GachaCharacter> get characterPool =>
      [..._rollablePool, ..._hiddenPool];

  // =========================================================================
  // 3. THUẬT TOÁN QUAY SỐ (HỖ TRỢ DUAL BANNER: USUAL & PREMIUM)
  // =========================================================================
  static Future<Map<String, dynamic>> rollCharacter(
      {bool isPremium = false,
      Map<String, GachaCharacter>? simulatedBox}) async {
    final random = Random();
    final rollPoint = random.nextDouble() * 100;

    String targetRank;

    if (isPremium) {
      // --- TỶ LỆ PREMIUM ROLL ---
      if (rollPoint <= 10.0) {
        targetRank = 'SR++';
      } else if (rollPoint <= 40.0) {
        targetRank = 'SR';
      } else if (rollPoint <= 90.0) {
        targetRank = 'A';
      } else if (rollPoint <= 95.0) {
        targetRank = 'E';
      } else {
        targetRank = 'F';
      }
    } else {
      // --- TỶ LỆ USUAL ROLL ---
      if (rollPoint <= 0.5) {
        targetRank = 'SR++';
      } else if (rollPoint <= 2.5) {
        targetRank = 'SR';
      } else if (rollPoint <= 7.0) {
        targetRank = 'A';
      } else if (rollPoint <= 15.0) {
        targetRank = 'B';
      } else if (rollPoint <= 27.0) {
        targetRank = 'C';
      } else if (rollPoint <= 45.0) {
        targetRank = 'D';
      } else if (rollPoint <= 70.0) {
        targetRank = 'E';
      } else {
        targetRank = 'F';
      }
    }

    var availableCharacters =
        _rollablePool.where((c) => c.rank == targetRank).toList();
    if (availableCharacters.isEmpty) {
      availableCharacters = _rollablePool.where((c) => c.rank == 'F').toList();
    }

    final rolledChar =
        availableCharacters[random.nextInt(availableCharacters.length)];
    return _simulateDrop(rolledChar, simulatedBox);
  }

  static Map<String, dynamic> _simulateDrop(
      GachaCharacter newChar, Map<String, GachaCharacter>? simulatedBox) {
    bool isShardChar = newChar.rank == 'SR++';
    bool isDuplicate = false;

    GachaCharacter charClone = GachaCharacter(
      id: newChar.id,
      name: newChar.name,
      rank: newChar.rank,
      baseCp: newChar.baseCp,
      personalityTags: List.from(newChar.personalityTags),
      isAnimated: newChar.isAnimated,
      borderImageUrl: newChar.borderImageUrl,
      ringtoneFile: newChar.ringtoneFile,
      isUnlocked: newChar.rank != 'SR++',
      shardCount: 1,
    );

    if (simulatedBox != null) {
      if (simulatedBox.containsKey(charClone.id)) {
        GachaCharacter existingChar = simulatedBox[charClone.id]!;
        if (isShardChar && !existingChar.isUnlocked) {
          isDuplicate = false;
          existingChar.shardCount += 1;
          if (existingChar.shardCount >= 3) {
            existingChar.isUnlocked = true;
          }
        } else {
          isDuplicate = true;
          existingChar.baseCp += (charClone.baseCp * 0.1).round();
        }
      } else {
        if (isShardChar) {
          charClone.isUnlocked = false;
          charClone.shardCount = 1;
        } else {
          charClone.isUnlocked = true;
        }
        simulatedBox[charClone.id] = charClone;
      }
    } else {
      final box = Hive.box<GachaCharacter>('characterBox');
      if (box.containsKey(charClone.id)) {
        GachaCharacter existingChar = box.get(charClone.id)!;
        if (isShardChar && !existingChar.isUnlocked) {
          isDuplicate = false;
        } else {
          isDuplicate = true;
        }
      }
    }
    return {'character': charClone, 'isDuplicate': isDuplicate};
  }

  // =========================================================================
  // 5. THUẬT TOÁN QUAY NHIỀU LƯỢT (HỖ TRỢ TRUYỀN CỜ isPremium)
  // =========================================================================
  static Future<List<Map<String, dynamic>>> rollMultiple(int count,
      {bool isPremium = false}) async {
    List<Map<String, dynamic>> results = [];
    final box = Hive.box<GachaCharacter>('characterBox');
    Map<String, GachaCharacter> simulatedBox = {};
    for (var key in box.keys) {
      final char = box.get(key)!;
      simulatedBox[key as String] = GachaCharacter(
        id: char.id,
        name: char.name,
        rank: char.rank,
        baseCp: char.baseCp,
        personalityTags: List.from(char.personalityTags),
        isAnimated: char.isAnimated,
        borderImageUrl: char.borderImageUrl,
        ringtoneFile: char.ringtoneFile,
        isUnlocked: char.isUnlocked,
        shardCount: char.shardCount,
      );
    }

    for (int i = 0; i < count; i++) {
      results.add(await rollCharacter(
          isPremium: isPremium, simulatedBox: simulatedBox));
    }

    results.sort((a, b) {
      final rankWeight = {
        'SR++': 6,
        'SR': 5,
        'A': 4,
        'B': 3,
        'C': 2,
        'D': 1,
        'E': 0,
        'F': -1
      };
      String rankA = (a['character'] as GachaCharacter).rank;
      String rankB = (b['character'] as GachaCharacter).rank;
      return (rankWeight[rankB] ?? -2).compareTo(rankWeight[rankA] ?? -2);
    });
    return results;
  }
}
