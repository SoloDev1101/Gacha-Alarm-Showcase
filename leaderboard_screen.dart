import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';

import '../models/user_profile.dart';
import '../models/character.dart';
import '../utils/logger.dart';

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  late UserProfile _currentUser;
  late String _currentRegion;
  late int _userTotalCp;

  final _supabase = Supabase.instance.client;

  bool _isLoading = true;
  List<Map<String, dynamic>> _topPlayers = [];
  int _myRank = -1;

  final List<String> _allRegions = [
    'Global',
    'Asia',
    'SEA',
    'NA',
    'EU',
    'OCE',
    'AU',
    'CN',
    'JP',
    'KR',
    'TH',
    'TW',
    'CH',
    'FR',
    'ES',
    'UK',
    'US',
    'VN',
    'Other'
  ];

  // BẢN ĐỒ PHÂN VÙNG QUỐC GIA (Dễ dàng thêm mới sau này ở duy nhất 1 chỗ)
  static const Map<String, List<String>> _regionMap = {
    'SEA': ['VN', 'TH'],
    'Asia': ['VN', 'TH', 'CN', 'JP', 'KR', 'TW'],
    'EU': ['FR', 'ES', 'CH', 'UK'],
    'NA': ['US'],
    'OCE': ['AU'],
  };

  @override
  void initState() {
    super.initState();
    _currentUser = Hive.box<UserProfile>('userProfileBox').getAt(0)!;
    _currentRegion = _currentUser.nationality;
    _userTotalCp = _calculateTotalCp();

    _fetchLeaderboardData();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndShowDailySummary();
    });
  }

  // =========================================================================
  // --- KẾT NỐI SERVER: LẤY BẢNG XẾP HẠNG THỰC TẾ ---
  // =========================================================================
  Future<void> _fetchLeaderboardData() async {
    setState(() => _isLoading = true);

    try {
      var query = _supabase.from('user_profiles').select(
          'id, nickname, nationality, total_cp, total_hearts, total_followers');

      // Logic chuyển đổi Khu vực -> Danh sách Quốc gia
      if (_currentRegion != 'Global') {
        List<String> targetCountries = [
          _currentRegion
        ]; // Mặc định là chính quốc gia đó

        if (_regionMap.containsKey(_currentRegion)) {
          targetCountries = _regionMap[_currentRegion]!;
        }

        query = query.inFilter('nationality', targetCountries);
      }

      final response =
          await query.order('total_cp', ascending: false).limit(30);

      int myCurrentRank = -1;
      for (int i = 0; i < response.length; i++) {
        if (response[i]['id'] == _supabase.auth.currentUser?.id) {
          myCurrentRank = i + 1;
          break;
        }
      }

      if (!mounted) return;
      setState(() {
        _topPlayers = List<Map<String, dynamic>>.from(response);
        _myRank = myCurrentRank;
        _isLoading = false;
      });
    } catch (e) {
      appLog("⚠️ Lỗi tải Bảng xếp hạng: $e");
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  // =========================================================================
  // --- LOGIC THẢ TIM & FOLLOW (ĐỒNG BỘ CLOUD VỚI OPTIMISTIC UI) ---
  // =========================================================================
  Future<void> _toggleInteraction(String targetUserId, String type) async {
    final myId = _supabase.auth.currentUser?.id;
    if (myId == null || targetUserId == myId) return;

    bool isHeart = type == 'heart';
    List<String> localList = isHeart
        ? List.from(_currentUser.likedUsers)
        : List.from(_currentUser.followedUsers);
    bool isCurrentlyActive = localList.contains(targetUserId);

    // 1. Cập nhật Local UI ngay lập tức (Optimistic UI)
    setState(() {
      if (isCurrentlyActive) {
        localList.remove(targetUserId);
        _updatePlayerStatLocally(targetUserId, isHeart, -1);
      } else {
        localList.add(targetUserId);
        _updatePlayerStatLocally(targetUserId, isHeart, 1);
      }

      if (isHeart) {
        _currentUser.likedUsers = localList;
      } else {
        _currentUser.followedUsers = localList;
      }
      _currentUser.save();
    });

    // 2. Gửi lệnh lên Supabase
    try {
      if (isCurrentlyActive) {
        await _supabase.from('user_interactions').delete().match({
          'from_user_id': myId,
          'target_user_id': targetUserId,
          'type': type
        });
      } else {
        await _supabase.from('user_interactions').insert({
          'from_user_id': myId,
          'target_user_id': targetUserId,
          'type': type
        });
      }
    } catch (e) {
      // Nếu Server lỗi, hoàn tác lại UI
      appLog("⚠️ Lỗi tương tác: $e");
      setState(() {
        if (isCurrentlyActive) {
          localList.add(targetUserId);
          _updatePlayerStatLocally(targetUserId, isHeart, 1);
        } else {
          localList.remove(targetUserId);
          _updatePlayerStatLocally(targetUserId, isHeart, -1);
        }
        if (isHeart) {
          _currentUser.likedUsers = localList;
        } else {
          _currentUser.followedUsers = localList;
        }
        _currentUser.save();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('gacha_service.sync_error'.tr())));
      }
    }
  }

  void _updatePlayerStatLocally(String targetId, bool isHeart, int change) {
    int index = _topPlayers.indexWhere((p) => p['id'] == targetId);
    if (index != -1) {
      if (isHeart) {
        _topPlayers[index]['total_hearts'] =
            (_topPlayers[index]['total_hearts'] ?? 0) + change;
      } else {
        _topPlayers[index]['total_followers'] =
            (_topPlayers[index]['total_followers'] ?? 0) + change;
      }
    }
  }

  // =========================================================================
  // --- THÔNG BÁO TỔNG HỢP 24H (Đồng bộ số liệu thật) ---
  // =========================================================================
  Future<void> _checkAndShowDailySummary() async {
    final myId = _supabase.auth.currentUser?.id;
    if (myId == null) return;

    final now = DateTime.now();
    final lastTime = _currentUser.lastLeaderboardPopupTime;

    if (lastTime == null || now.difference(lastTime).inHours >= 24) {
      try {
        // Lấy số liệu mới nhất của bản thân từ Server
        final myData = await _supabase
            .from('user_profiles')
            .select('total_hearts, total_followers')
            .eq('id', myId)
            .single();

        int currentHearts = myData['total_hearts'] ?? 0;
        int currentFollowers = myData['total_followers'] ?? 0;

        int newHearts = currentHearts - _currentUser.lastSeenHearts;
        int newFollowers = currentFollowers - _currentUser.lastSeenFollowers;

        if (newHearts > 0 || newFollowers > 0) {
          _showSummaryPopup(newHearts, newFollowers);
        }

        if (!mounted) return;
        setState(() {
          _currentUser.totalHeartsReceived = currentHearts;
          _currentUser.totalFollowers = currentFollowers;
          _currentUser.lastSeenHearts = currentHearts;
          _currentUser.lastSeenFollowers = currentFollowers;
          _currentUser.lastLeaderboardPopupTime = now;
        });
        _currentUser.save();
      } catch (e) {
        appLog("⚠️ Lỗi cập nhật Summary: $e");
      }
    }
  }

  void _showSummaryPopup(int newHearts, int newFollowers) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2C),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Colors.amber)),
        title: Text('leaderboard.daily_summary_title'.tr(),
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.amber, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('leaderboard.daily_summary_desc'.tr(),
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.favorite, color: Colors.white, size: 28),
                const SizedBox(width: 8),
                Text("+$newHearts",
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.person, color: Colors.white, size: 28),
                const SizedBox(width: 8),
                Text("+$newFollowers",
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
        actions: [
          Center(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
              onPressed: () => Navigator.pop(ctx),
              child: Text('leaderboard.awesome_btn'.tr(),
                  style: const TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          )
        ],
      ),
    );
  }

  // --- HÀM TÍNH TỔNG CP (Dùng Local cho người chơi hiện tại) ---
  int _calculateTotalCp() {
    final charBox = Hive.box<GachaCharacter>('characterBox');
    int total = 0;
    for (var char in charBox.values) {
      total += char.baseCp;
    }
    return total;
  }

  String _formatCP(int cp) {
    return NumberFormat.compact(locale: "en_US").format(cp);
  }

  List<String> _getRecommendedRegions(String nationality) {
    Set<String> rec = {nationality, 'Global'};
    _regionMap.forEach((regionName, countries) {
      if (countries.contains(nationality)) {
        rec.add(regionName);
      }
    });
    return rec.toList();
  }

  void _showRegionPicker() {
    final recommended = _getRecommendedRegions(_currentUser.nationality);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E2C),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  Text('leaderboard.recommended'.tr(),
                      style: const TextStyle(
                          color: Colors.amber,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                  const SizedBox(height: 12),
                  Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: recommended
                          .map<Widget>((r) => _buildRegionChip(r, true))
                          .toList()),
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Divider(color: Colors.white12)),
                  Text('leaderboard.all_regions'.tr(),
                      style: const TextStyle(
                          color: Colors.white54,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                  const SizedBox(height: 12),
                  Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: _allRegions
                          .map<Widget>((r) => _buildRegionChip(r, false))
                          .toList()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRegionChip(String region, bool isRecommended) {
    bool isSelected = _currentRegion == region;
    return GestureDetector(
      onTap: () {
        setState(() => _currentRegion = region);
        Navigator.pop(context);
        _fetchLeaderboardData(); // Tải lại danh sách khi đổi Region
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.amber.withOpacity(0.2)
              : Colors.white.withOpacity(0.05),
          border: Border.all(
              color: isSelected ? Colors.amber : Colors.white12, width: 1.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(region,
            style: TextStyle(
                color: isSelected ? Colors.amber : Colors.white,
                fontWeight: FontWeight.bold)),
      ),
    );
  }

  // =========================================================================
  // --- GIAO DIỆN THẺ NGƯỜI CHƠI ---
  // =========================================================================
  Widget _buildPlayerRow(int rank, String id, String name, String nationality,
      int cp, int hearts, int followers, bool isCurrentUser,
      {bool isStickyBar = false}) {
    Color rankColor = Colors.white54;
    if (rank == 1) rankColor = const Color(0xFFFFD700);
    if (rank == 2) rankColor = const Color(0xFFC0C0C0);
    if (rank == 3) rankColor = const Color(0xFFCD7F32);

    bool isLiked = _currentUser.likedUsers.contains(id);
    bool isFollowed = _currentUser.followedUsers.contains(id);

    return Container(
      margin: EdgeInsets.only(bottom: isStickyBar ? 0 : 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isCurrentUser
            ? Colors.amber.withOpacity(0.15)
            : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(16),
        border: isCurrentUser
            ? Border.all(color: Colors.amber, width: isStickyBar ? 2 : 1)
            : Border.all(color: Colors.white12),
        boxShadow: isStickyBar
            ? [
                BoxShadow(
                    color: Colors.amber.withOpacity(0.2),
                    blurRadius: 10,
                    spreadRadius: 1)
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                  width: 40,
                  child: Text('#$rank',
                      style: TextStyle(
                          color: rankColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          fontStyle: FontStyle.italic))),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                        child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color:
                                    isCurrentUser ? Colors.amber : Colors.white,
                                fontWeight: isCurrentUser
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                fontSize: 16))),
                    const SizedBox(width: 6),
                    Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(4)),
                        child: Text(nationality,
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)))
                  ],
                ),
              ),
              SizedBox(
                  width: 60,
                  child: Text(_formatCP(cp),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 14))),
            ],
          ),
          if (!isStickyBar) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox(width: 40),
                if (!isCurrentUser) ...[
                  GestureDetector(
                    onTap: () => _toggleInteraction(id, 'heart'),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                          color: isLiked
                              ? Colors.white.withOpacity(0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: isLiked ? Colors.white : Colors.white24)),
                      child: Row(
                        children: [
                          Icon(isLiked ? Icons.favorite : Icons.favorite_border,
                              color: Colors.white, size: 14),
                          const SizedBox(width: 6),
                          Text(_formatCP(hearts),
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: isLiked
                                      ? FontWeight.bold
                                      : FontWeight.normal))
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => _toggleInteraction(id, 'follow'),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                          color: isFollowed
                              ? Colors.white.withOpacity(0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color:
                                  isFollowed ? Colors.white : Colors.white24)),
                      child: Row(
                        children: [
                          Icon(
                              isFollowed
                                  ? Icons.person
                                  : Icons.person_add_outlined,
                              color: Colors.white,
                              size: 14),
                          const SizedBox(width: 6),
                          Text(_formatCP(followers),
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: isFollowed
                                      ? FontWeight.bold
                                      : FontWeight.normal))
                        ],
                      ),
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      const Icon(Icons.favorite,
                          color: Colors.white54, size: 14),
                      const SizedBox(width: 4),
                      Text(_formatCP(hearts),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                      const SizedBox(width: 16),
                      const Icon(Icons.person, color: Colors.white54, size: 14),
                      const SizedBox(width: 4),
                      Text(_formatCP(followers),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                    ],
                  )
                ]
              ],
            )
          ],
          if (isStickyBar) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(width: 40),
                const Icon(Icons.favorite, color: Colors.white54, size: 14),
                const SizedBox(width: 4),
                Text(_formatCP(_currentUser.totalHeartsReceived),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(width: 16),
                const Icon(Icons.person, color: Colors.white54, size: 14),
                const SizedBox(width: 4),
                Text(_formatCP(_currentUser.totalFollowers),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            )
          ]
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F16),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('leaderboard.title'.tr(),
            style: const TextStyle(
                color: Colors.amber, fontWeight: FontWeight.bold)),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.amber),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: InkWell(
              onTap: _showRegionPicker,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      Colors.amber.withOpacity(0.2),
                      Colors.transparent
                    ]),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.amber.withOpacity(0.3))),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('leaderboard.region'.tr(args: [_currentRegion]),
                        style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const Icon(Icons.arrow_drop_down_circle,
                        color: Colors.amber),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.amber))
                : _topPlayers.isEmpty
                    ? Center(
                        child: Text("leaderboard.no_data".tr(),
                            style: const TextStyle(color: Colors.white54)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                        itemCount: _topPlayers.length,
                        itemBuilder: (context, index) {
                          final p = _topPlayers[index];
                          bool isMe = p['id'] == _supabase.auth.currentUser?.id;
                          return _buildPlayerRow(
                              index + 1,
                              p['id'],
                              p['nickname'],
                              p['nationality'],
                              p['total_cp'],
                              p['total_hearts'] ?? 0,
                              p['total_followers'] ?? 0,
                              isMe);
                        },
                      ),
          ),
        ],
      ),
      bottomSheet: Container(
        color: const Color(0xFF0F0F16),
        padding: const EdgeInsets.only(bottom: 16, left: 16, right: 16, top: 8),
        child: SafeArea(
          child: _buildPlayerRow(
            _myRank > 0 ? _myRank : 999,
            _supabase.auth.currentUser?.id ?? '',
            _currentUser.nickname,
            _currentUser.nationality,
            _userTotalCp,
            _currentUser.totalHeartsReceived,
            _currentUser.totalFollowers,
            true,
            isStickyBar: true,
          ).buildMyRankWrapper(_myRank),
        ),
      ),
    );
  }
}

extension RankWrapper on Widget {
  Widget buildMyRankWrapper(int rank) {
    if (rank > 0) return this;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('leaderboard.unranked'.tr(),
              style: const TextStyle(
                  color: Colors.white54, fontStyle: FontStyle.italic)),
          const Icon(Icons.public_off, color: Colors.white24),
        ],
      ),
    );
  }
}
