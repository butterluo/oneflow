/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#ifndef ONEFLOW_CORE_COMMON_OBJECT_POOL_H_
#define ONEFLOW_CORE_COMMON_OBJECT_POOL_H_

#include <mutex>
#include <vector>
#include <memory>
#include "oneflow/core/common/cpp_attribute.h"

namespace oneflow {

namespace obj_pool {

template<typename T>
struct RawPtrConstructor final {
  using return_type = T*;

  template<typename... Args>
  static return_type Construct(Args&&... args) {
    return new T(std::forward<Args>(args)...);
  }
};

template<typename T>
class VectorPoolContainer final {
 public:
  VectorPoolContainer() = default;
  ~VectorPoolContainer() = default;

  std::size_t size() const { return container_.size(); }
  std::size_t thread_unsafe_size() const { return container_.size(); }

  void PushBack(T&& object) { container_.push_back(std::move(object)); }
  T PopBack() {
    T object = container_.at(container_.size() - 1);
    container_.pop_back();
    return object;
  }
  void MoveTo(VectorPoolContainer* other) {
    other->container_.insert(other->container_.end(), this->container_.begin(),
                             this->container_.end());
    container_.clear();
  }

 private:
  std::vector<T> container_;
};

template<typename T, int kThreadLocalMax = 1024,
         template<typename> class PtrConstructor = RawPtrConstructor,
         template<typename> class PoolContainer = VectorPoolContainer>
struct ObjectPool final {
  using ptr_type = typename PtrConstructor<T>::return_type;

  // Returned object has not been destructed yet.
  static ptr_type GetRecycled() {
    if (unlikely(MutLocalRecycledPool()->size())) { return MutLocalRecycledPool()->PopBack(); }
    if (likely(MutLocalRecyclingPool()->size())) { return MutLocalRecyclingPool()->PopBack(); }
    if (unlikely(MutGlobalRecycledPool()->thread_unsafe_size())) {
      {
        std::unique_lock<std::mutex> lock(*MutMutex());
        MutGlobalRecycledPool()->MoveTo(MutLocalRecycledPool());
      }
      return MutLocalRecycledPool()->PopBack();
    }
    return nullptr;
  }
  template<typename... Args>
  static ptr_type GetOrNew(Args&&... args) {
    ptr_type recycled = GetRecycled();
    if (likely(recycled != nullptr)) {
      return DestructThenConstruct(recycled, std::forward<Args>(args)...);
    } else {
      return PtrConstructor<T>::Construct(std::forward<Args>(args)...);
    }
  }

  static void Put(ptr_type object) {
    auto* local_recycling_pool = MutLocalRecyclingPool();
    local_recycling_pool->PushBack(std::move(object));
    if (unlikely(local_recycling_pool->size() > kThreadLocalMax)) {
      std::unique_lock<std::mutex> lock(*MutMutex());
      local_recycling_pool->MoveTo(MutGlobalRecycledPool());
    }
  }

 private:
  template<typename... Args>
  static ptr_type DestructThenConstruct(ptr_type ptr, Args&&... args) {
    (*ptr).~T();
    new (&*ptr) T(std::forward<Args>(args)...);
    return ptr;
  }

  static PoolContainer<ptr_type>* MutLocalRecycledPool() {
    thread_local auto* pool = new PoolContainer<ptr_type>();
    return pool;
  }
  static PoolContainer<ptr_type>* MutLocalRecyclingPool() {
    thread_local auto* pool = new PoolContainer<ptr_type>();
    return pool;
  }
  static PoolContainer<ptr_type>* MutGlobalRecycledPool() {
    static auto* pool = new PoolContainer<ptr_type>();
    return pool;
  }
  static std::mutex* MutMutex() {
    static std::mutex mutex;
    return &mutex;
  }
};

template<typename T>
class shared_ptr final {
 public:
  using value_type = T;
  using object_pool_type = ObjectPool<T>;

  shared_ptr(const shared_ptr&) = default;
  shared_ptr(shared_ptr&) = default;

  shared_ptr() = default;
  ~shared_ptr() = default;

  value_type* get() const { return recycled_ptr_.get(); }
  explicit operator bool() const { return get() != nullptr; }
  bool operator==(const shared_ptr& rhs) const { return this->recycled_ptr_ == rhs.recycled_ptr_; }
  value_type* operator->() const { return get(); }
  value_type& operator*() const { return *get(); }

  shared_ptr& operator=(const shared_ptr& rhs) = default;
  shared_ptr& operator=(shared_ptr&& rhs) = default;

  void reset() { recycled_ptr_.reset(); }

  template<typename... Args>
  static shared_ptr Make(Args&&... args) {
    return shared_ptr(object_pool_type::GetOrNew(std::forward<Args>(args)...));
  }

 private:
  explicit shared_ptr(T* ptr) : recycled_ptr_(ptr, &object_pool_type::Put) {}

  std::shared_ptr<T> recycled_ptr_;
};

template<typename T, typename... Args>
shared_ptr<T> make_shared(Args&&... args) {
  return shared_ptr<T>::Make(std::forward<Args>(args)...);
}

}  // namespace obj_pool

}  // namespace oneflow

#endif  // ONEFLOW_CORE_COMMON_OBJECT_POOL_H_
