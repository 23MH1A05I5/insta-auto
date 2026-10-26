import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instauto/models/backfill_model.dart';

void main() {
  group('Backfill Model Tests', () {
    test('BackfillPreviewResponse parses JSON correctly', () {
      final json = {
        'totalComments': 12,
        'eligibleCount': 4,
        'alreadyProcessedCount': 3,
        'unmatchedCount': 4,
        'expiredDmCount': 1,
        'comments': [
          {
            'commentId': 'c1',
            'username': 'john_doe',
            'text': 'How much does this cost?',
            'timestamp': '2026-03-01T12:00:00Z',
            'isEligible': true,
            'status': 'eligible',
            'reason': null,
            'isOlderThan7Days': false,
            'willSendPublicReply': true,
            'willSendDm': true,
          },
          {
            'commentId': 'c2',
            'username': 'jane_doe',
            'text': 'Cool post',
            'timestamp': '2026-03-01T12:05:00Z',
            'isEligible': false,
            'status': 'unmatched',
            'reason': 'Did not match trigger keywords',
            'isOlderThan7Days': false,
            'willSendPublicReply': false,
            'willSendDm': false,
          },
          {
            'commentId': 'c3',
            'username': 'old_user',
            'text': 'price please',
            'timestamp': '2026-01-01T12:00:00Z',
            'isEligible': true,
            'status': 'expired_dm_eligible_public_reply',
            'reason': 'Comment is older than 7 days: DM skipped per Meta policy, public reply eligible',
            'isOlderThan7Days': true,
            'willSendPublicReply': true,
            'willSendDm': false,
          },
        ],
      };

      final response = BackfillPreviewResponse.fromJson(json);

      expect(response.totalComments, equals(12));
      expect(response.eligibleCount, equals(4));
      expect(response.alreadyProcessedCount, equals(3));
      expect(response.unmatchedCount, equals(4));
      expect(response.expiredDmCount, equals(1));
      expect(response.comments.length, equals(3));

      // Test first comment
      final c1 = response.comments[0];
      expect(c1.commentId, equals('c1'));
      expect(c1.username, equals('john_doe'));
      expect(c1.isEligible, isTrue);
      expect(c1.willSendPublicReply, isTrue);
      expect(c1.willSendDm, isTrue);
      expect(c1.isOlderThan7Days, isFalse);

      // Test unmatched comment
      final c2 = response.comments[1];
      expect(c2.isEligible, isFalse);
      expect(c2.status, equals('unmatched'));
      expect(c2.reason, contains('Did not match'));

      // Test >7d comment
      final c3 = response.comments[2];
      expect(c3.isEligible, isTrue);
      expect(c3.isOlderThan7Days, isTrue);
      expect(c3.willSendPublicReply, isTrue);
      expect(c3.willSendDm, isFalse);
    });

    test('BackfillJobModel handles progress, states, and failed DMs', () {
      final json = {
        '_id': 'job_123',
        'automationId': 'auto_456',
        'mediaId': 'media_789',
        'status': 'processing',
        'totalComments': 10,
        'processedCount': 5,
        'successCount': 4,
        'failedCount': 1,
        'skippedCount': 0,
        'actions': [
          {
            'commentId': 'c1',
            'username': 'user1',
            'commentText': 'send link',
            'publicReplyStatus': 'sent',
            'dmStatus': 'failed',
            'dmError': 'Meta Graph API Network Error',
            'canRetryDm': true,
          },
          {
            'commentId': 'c2',
            'username': 'user2',
            'commentText': 'how much',
            'publicReplyStatus': 'sent',
            'dmStatus': 'sent',
            'canRetryDm': false,
          },
        ],
      };

      final job = BackfillJobModel.fromJson(json);

      expect(job.id, equals('job_123'));
      expect(job.isProcessing, isTrue);
      expect(job.isCompleted, isFalse);
      expect(job.progressPercentage, equals(0.5));
      expect(job.hasFailedDms, isTrue);
      expect(job.actions.length, equals(2));
      expect(job.actions[0].canRetryDm, isTrue);
      expect(job.actions[1].canRetryDm, isFalse);
    });

    test('BackfillJobModel completed state calculation', () {
      final json = {
        '_id': 'job_completed',
        'automationId': 'auto_456',
        'mediaId': 'media_789',
        'status': 'completed',
        'totalComments': 2,
        'processedCount': 2,
        'successCount': 2,
        'failedCount': 0,
        'skippedCount': 0,
        'actions': [],
      };

      final job = BackfillJobModel.fromJson(json);

      expect(job.isProcessing, isFalse);
      expect(job.isCompleted, isTrue);
      expect(job.progressPercentage, equals(1.0));
      expect(job.hasFailedDms, isFalse);
    });
  });

  group('Backfill UI Widget Rendering Tests', () {
    testWidgets('Renders progress bar and status indicator correctly', (tester) async {
      const job = BackfillJobModel(
        id: 'job_test',
        automationId: 'auto_1',
        mediaId: 'media_1',
        status: 'processing',
        totalComments: 10,
        processedCount: 7,
        successCount: 6,
        failedCount: 1,
        skippedCount: 0,
        actions: [
          BackfillActionItem(
            commentId: 'c1',
            username: 'test_user',
            commentText: 'link please',
            publicReplyStatus: 'sent',
            dmStatus: 'failed',
            dmError: 'Connection timed out',
            canRetryDm: true,
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Text('Progress: ${(job.progressPercentage * 100).toInt()}%'),
                LinearProgressIndicator(value: job.progressPercentage),
                Text('Success: ${job.successCount}'),
                Text('Failed: ${job.failedCount}'),
                if (job.hasFailedDms)
                  ElevatedButton(
                    onPressed: () {},
                    child: const Text('Retry Failed DMs'),
                  ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Progress: 70%'), findsOneWidget);
      expect(find.text('Success: 6'), findsOneWidget);
      expect(find.text('Failed: 1'), findsOneWidget);
      expect(find.text('Retry Failed DMs'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });
  });
}
