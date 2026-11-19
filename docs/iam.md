# MeeTap 最小 IAM 权限

> 从 README 挪过来的。给 MeeTap 使用的 IAM 用户或角色附加下面的策略（按需启用 SES 部分）。用管理员凭证也能跑，这一页是给想收紧权限的人看的。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ObjectOps",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutBucketPublicAccessBlock"
      ],
      "Resource": [
        "arn:aws:s3:::meetap-transcribe-*",
        "arn:aws:s3:::meetap-transcribe-*/*"
      ]
    },
    {
      "Sid": "TranscribeStartJob",
      "Effect": "Allow",
      "Action": ["transcribe:StartTranscriptionJob"],
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:RequestedRegion": "us-east-1" }
      }
    },
    {
      "Sid": "TranscribeGetDeleteJob",
      "Effect": "Allow",
      "Action": [
        "transcribe:GetTranscriptionJob",
        "transcribe:DeleteTranscriptionJob"
      ],
      "Resource": "arn:aws:transcribe:us-east-1:*:transcription-job/meetap-*"
    },
    {
      "Sid": "BedrockInvoke",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModelWithResponseStream"],
      "Resource": [
        "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-*",
        "arn:aws:bedrock:us-east-1:*:inference-profile/us.anthropic.claude-sonnet-4-*"
      ]
    },
    {
      "Sid": "SESSendFromConfiguredSender",
      "Effect": "Allow",
      "Action": ["ses:SendRawEmail"],
      "Resource": "arn:aws:ses:us-east-1:*:identity/noreply@example.com",
      "Condition": {
        "StringEquals": {
          "ses:FromAddress": "noreply@example.com"
        }
      }
    }
  ]
}
```

**最小权限说明**（按实际调用收紧，切 region / 换模型时记得同步 ARN）：

- **S3**：meetap 首次运行会自动建桶（`meetap-transcribe-<AccountID 短哈希>-<region>`），不用手动预建。这份策略没有建桶权限，所以**套用时首次运行请临时补上 `s3:CreateBucket`**（跑一次后可收回），或手动预建同名桶。策略里也没有 `s3:ListBucket`：meetap 查桶在不在时查不到、建桶时报权限不够，都不算失败，照常上传。
- **Transcribe**：`StartTranscriptionJob` 不支持资源级 ARN，只能 `Resource:"*"` + `aws:RequestedRegion` 锁 region；`Get/Delete` 已收窄到 `transcription-job/meetap-*`。
- **Bedrock**：生成纪要和认日历都走流式接口，只要 `bedrock:InvokeModelWithResponseStream`。ARN 锁在 `us-east-1`，换 region 或模型（Nova / Llama / DeepSeek 等）需同步调整。注意默认模型 `global.anthropic.claude-sonnet-5` 是跨区域的推理配置文件，上面示例里的 ARN 是按 Sonnet 4 的区域内配置写的，用默认模型时要换成对应的推理配置文件和基础模型 ARN。
- **SES**：把两处 `noreply@example.com` 换成你**已在 SES 验证**的发件地址，且 ARN 的 region 要与验证 region 一致（SES 按 region 独立验证）；验证整个域时改用域 identity ARN（`identity/example.com`）。**新账户默认 sandbox**，只能发给已验证地址，群发需先申请生产访问。
