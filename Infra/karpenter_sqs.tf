# =========================
# SQS Queue — Karpenter Spot Interruption Events
# =========================
resource "aws_sqs_queue" "karpenter_interruption" {
  name                       = "${var.cluster_name}-karpenter-spot-events"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 300     # 5 minutes — time for Karpenter to process
  delay_seconds              = 0       # immediate delivery
  sqs_managed_sse_enabled    = true    # server-side encryption

  tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# Allow EventBridge to send messages to the SQS queue
resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "events.amazonaws.com" },
      Action    = "sqs:SendMessage",
      Resource  = aws_sqs_queue.karpenter_interruption.arn,
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = [
            aws_cloudwatch_event_rule.spot_interruption.arn,
            aws_cloudwatch_event_rule.rebalance_recommendation.arn,
            aws_cloudwatch_event_rule.instance_state_change.arn,
            aws_cloudwatch_event_rule.scheduled_change.arn
          ]
        }
      }
    }]
  })
}

# =========================
# EventBridge Rule 1 — EC2 Spot Interruption Warning
# Fires 2 minutes before AWS reclaims the Spot instance
# =========================
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-karpenter-spot-interruption"
  description = "Capture EC2 Spot Instance Interruption Warnings for Karpenter"

  event_pattern = jsonencode({
    source      = ["aws.ec2"],
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "karpenter-spot-events"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# =========================
# EventBridge Rule 2 — EC2 Instance Rebalance Recommendation
# Notifies when a Spot instance is at elevated risk; replace early
# =========================
resource "aws_cloudwatch_event_rule" "rebalance_recommendation" {
  name        = "${var.cluster_name}-karpenter-rebalance-recommendation"
  description = "Capture EC2 Instance Rebalance Recommendations for Karpenter"

  event_pattern = jsonencode({
    source      = ["aws.ec2"],
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "rebalance_recommendation" {
  rule      = aws_cloudwatch_event_rule.rebalance_recommendation.name
  target_id = "karpenter-spot-events"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# =========================
# EventBridge Rule 3 — EC2 Instance State Change
# Catches unexpected terminations
# =========================
resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${var.cluster_name}-karpenter-instance-state-change"
  description = "Capture EC2 Instance State-change Notifications for Karpenter"

  event_pattern = jsonencode({
    source      = ["aws.ec2"],
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "karpenter-spot-events"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# =========================
# EventBridge Rule 4 — AWS Health Scheduled Change
# Catches AWS maintenance events for nodes
# =========================
resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name        = "${var.cluster_name}-karpenter-scheduled-change"
  description = "Capture AWS Health Scheduled Change events for Karpenter"

  event_pattern = jsonencode({
    source      = ["aws.health"],
    detail-type = ["AWS Health Event"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "scheduled_change" {
  rule      = aws_cloudwatch_event_rule.scheduled_change.name
  target_id = "karpenter-spot-events"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}
