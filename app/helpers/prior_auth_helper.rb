module PriorAuthHelper
  # [bg, fg, label] for a criterion verdict. A "met" is only styled green when
  # actually verified (grounded); anything else reads as a gap.
  def prior_auth_verdict_badge(verdict, verified)
    case verdict.to_s
    when "met"
      verified ? [ "#E6F0EA", "#2F6F4E", "Met" ] : [ "#F3ECDD", "#8C6A2F", "Unverified" ]
    when "unmet"          then [ "#FBEAE8", "#C1403A", "Not met" ]
    when "not_documented" then [ "#F0F0EE", "#6B665F", "Not documented" ]
    else                       [ "#F3ECDD", "#8C6A2F", "Uncertain" ]
    end
  end

  # [bg, border, fg, label] for the overall recommendation banner.
  def prior_auth_recommendation_style(recommendation)
    case recommendation.to_s
    when "approve" then [ "#E6F0EA", "#2F6F4E", "#235c3e", "Approve" ]
    when "deny"    then [ "#FBEAE8", "#C1403A", "#9A2F2A", "Deny" ]
    when "gap"     then [ "#FFF3EC", "#D97757", "#B4692A", "Gaps to resolve" ]
    else                [ "#F0F0EE", "#6B665F", "#6B665F", "Pending" ]
    end
  end
end
