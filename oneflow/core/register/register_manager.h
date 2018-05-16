#ifndef ONEFLOW_CORE_REGISTER_REGISTER_MANAGER_H_
#define ONEFLOW_CORE_REGISTER_REGISTER_MANAGER_H_

#include "oneflow/core/job/id_manager.h"
#include "oneflow/core/job/plan.pb.h"
#include "oneflow/core/job/runtime_context.h"
#include "oneflow/core/memory/memory_allocator.h"
#include "oneflow/core/register/register.h"
#include "oneflow/core/record/record.pb.h"

namespace oneflow {

class RegstMgr final {
 public:
  OF_DISALLOW_COPY_AND_MOVE(RegstMgr);
  ~RegstMgr() = default;

  void NewRegsts(const RegstDescProto& regst_desc_proto, DeviceType device_type,
                 RecordTypeProto record_type, std::function<void(Regst*)> OneRegstDone);

 private:
  friend class Global<RegstMgr>;
  RegstMgr() = default;

  std::mutex rt_regst_descs_mtx_;
  std::list<std::unique_ptr<const RtRegstDesc>> rt_regst_descs_;
};

}  // namespace oneflow

#endif  // ONEFLOW_CORE_REGISTER_REGISTER_MANAGER_H_
