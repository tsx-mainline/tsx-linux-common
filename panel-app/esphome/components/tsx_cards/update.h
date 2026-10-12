// update.h: the ESPHome update entity "Update" of the panel app. See
// docs/panel-app.md, "Updates". ESPHome has no template update platform, so
// the platform tsx_cards (update.py) makes this class.
#pragma once

#include "esphome/core/defines.h"

#ifdef USE_UPDATE
#include "esphome/core/component.h"
#include "esphome/components/update/update_entity.h"

namespace esphome {
namespace tsx_cards {

class TsxCards;

class TsxUpdate : public update::UpdateEntity, public PollingComponent {
 public:
  void set_parent(TsxCards *parent) { this->parent_ = parent; }
  void setup() override;
  void update() override;
  void dump_config() override;
  float get_setup_priority() const override { return setup_priority::LATE; }

  /// Install: tsx-autoupdate installs at once. A restart follows when the
  /// update needs one and the automatic restart is on. With nothing to
  /// install and a restart required, the panel restarts.
  void perform(bool force) override;
  /// Read the state file now.
  void check() override;

 protected:
  void refresh_(bool force);
  TsxCards *parent_{nullptr};
};

}  // namespace tsx_cards
}  // namespace esphome
#endif
