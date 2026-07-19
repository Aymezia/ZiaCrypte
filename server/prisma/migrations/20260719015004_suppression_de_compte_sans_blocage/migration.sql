-- DropForeignKey
ALTER TABLE "conversations" DROP CONSTRAINT "conversations_created_by_fkey";

-- DropForeignKey
ALTER TABLE "message_blobs" DROP CONSTRAINT "message_blobs_recipient_device_id_fkey";

-- DropForeignKey
ALTER TABLE "message_blobs" DROP CONSTRAINT "message_blobs_sender_device_id_fkey";

-- AlterTable
ALTER TABLE "conversations" ALTER COLUMN "created_by" DROP NOT NULL;

-- AddForeignKey
ALTER TABLE "conversations" ADD CONSTRAINT "conversations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "message_blobs" ADD CONSTRAINT "message_blobs_sender_device_id_fkey" FOREIGN KEY ("sender_device_id") REFERENCES "devices"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "message_blobs" ADD CONSTRAINT "message_blobs_recipient_device_id_fkey" FOREIGN KEY ("recipient_device_id") REFERENCES "devices"("id") ON DELETE CASCADE ON UPDATE CASCADE;

