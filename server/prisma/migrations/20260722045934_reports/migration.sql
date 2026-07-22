-- CreateEnum
CREATE TYPE "ReportStatus" AS ENUM ('open', 'resolved', 'dismissed');

-- CreateTable
CREATE TABLE "reports" (
    "id" UUID NOT NULL,
    "reporter_user_id" UUID,
    "reporter_label" TEXT,
    "reported_user_id" UUID,
    "reported_label" TEXT,
    "reason" TEXT NOT NULL,
    "note" TEXT,
    "content" TEXT,
    "context" TEXT,
    "status" "ReportStatus" NOT NULL DEFAULT 'open',
    "handled_by_user_id" UUID,
    "handled_at" TIMESTAMP(3),
    "resolution" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "reports_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "reports_status_created_at_idx" ON "reports"("status", "created_at");

-- CreateIndex
CREATE INDEX "reports_reported_user_id_idx" ON "reports"("reported_user_id");
