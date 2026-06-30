# Refreshes the cached list of Medicare hospice LCDs from the live CMS Coverage
# API so Cms::HospiceCoverage cites current LCD ids/links. Keeps the request
# path I/O-free: the eval never calls CMS — it reads this warm cache (with a
# verified baked-in fallback). Scheduled daily in config/recurring.yml.
#   bin/rails runner 'CmsHospiceLcdRefreshJob.perform_now'
class CmsHospiceLcdRefreshJob < ApplicationJob
  queue_as :default

  def perform
    lcds = Cms::CoverageApi.refresh_hospice_lcds!
    Rails.logger.info("[CmsHospiceLcdRefreshJob] hospice LCDs cached=#{lcds.size}")
  end
end
